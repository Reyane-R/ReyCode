defmodule ReyCode.Provider.OpenCodeTest do
  use ExUnit.Case, async: false

  alias ReyCode.Provider.{Command, OpenCode, Request, Runtime}
  alias ReyCode.Security.Environment

  test "discovers credentials and stable provider/model identifiers" do
    runner = fn _executable, args, _opts ->
      case args do
        ["--version"] -> {:ok, "1.18.11\n"}
        ["auth", "list"] -> {:ok, "OpenAI oauth\nOpenRouter api\n2 credentials\n"}
        ["models"] -> {:ok, "openai/gpt-5.6-sol\nnoise\nopenrouter/qwen/qwen3\n"}
      end
    end

    assert {:ok, discovery} =
             OpenCode.discover(executable: "/tmp/opencode", runner: runner)

    assert discovery.version == "1.18.11"
    assert discovery.credential_count == 2
    assert discovery.models == ["openai/gpt-5.6-sol", "openrouter/qwen/qwen3"]
  end

  test "discovers models when display metadata commands fail" do
    runner = fn _executable, args, _opts ->
      case args do
        ["models"] -> {:ok, "openai/gpt-5.6-sol\n"}
        ["--version"] -> {:error, :timeout}
        ["auth", "list"] -> {:error, {:exit_status, 1, "not signed in"}}
      end
    end

    assert {:ok,
            %{
              executable: "/tmp/opencode",
              version: "unknown",
              credential_count: 0,
              models: ["openai/gpt-5.6-sol"]
            }} = OpenCode.discover(executable: "/tmp/opencode", runner: runner)
  end

  test "returns a model command failure from discovery" do
    runner = fn _executable, ["models"], _opts ->
      {:error, {:exit_status, 7, "model catalog unavailable\n"}}
    end

    assert {:error, "model catalog unavailable"} =
             OpenCode.discover(executable: "/tmp/opencode", runner: runner)
  end

  test "maps OpenCode JSON output into session and text frames" do
    path = fake_opencode(json_line("Hello from OpenCode"))
    test_pid = self()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{session_id: "session-1"}} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :session_started, sequence: 1}}

    assert_receive {:frame,
                    %{kind: :text_delta, sequence: 2, data: %{text: "Hello from OpenCode"}}}
  end

  test "runs OpenCode in the request workspace and passes the same --dir" do
    workspace =
      Path.join(System.tmp_dir!(), "rey_code_workspace_#{System.unique_integer([:positive])}")

    capture_path =
      Path.join(System.tmp_dir!(), "rey_code_pwd_#{System.unique_integer([:positive])}")

    args_path =
      Path.join(System.tmp_dir!(), "rey_code_args_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    path =
      fake_opencode("""
      printf '%s\n' "$PWD" > '#{capture_path}'
      printf '%s\n' "$@" > '#{args_path}'
      #{json_line("workspace confirmed")}
      """)

    on_exit(fn ->
      File.rm_rf(workspace)
      File.rm(path)
      File.rm(capture_path)
      File.rm(args_path)
    end)

    assert {:ok, _metadata} =
             OpenCode.stream(runtime(path), %{request() | workspace: workspace}, fn _frame ->
               :ok
             end)

    actual_workspace = File.stat!(String.trim(File.read!(capture_path)))
    requested_workspace = File.stat!(workspace)

    assert {actual_workspace.major_device, actual_workspace.inode} ==
             {requested_workspace.major_device, requested_workspace.inode}

    args = File.read!(args_path) |> String.split("\n", trim: true)

    canonical_workspace = capture_path |> File.read!() |> String.trim()

    assert Enum.chunk_every(args, 2, 1, :discard)
           |> Enum.member?(["--dir", canonical_workspace])
  end

  test "uses the executable captured by discovery rather than the current environment" do
    discovered = fake_opencode(json_line("discovered executable"))
    configured_later = fake_opencode(json_line("environment executable"))
    test_pid = self()
    previous = Application.get_env(:rey_code, :opencode_path)
    Application.put_env(:rey_code, :opencode_path, configured_later)

    on_exit(fn ->
      restore_env(:opencode_path, previous)
      File.rm(discovered)
      File.rm(configured_later)
    end)

    assert {:ok, _metadata} =
             OpenCode.stream(runtime(discovered), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "discovered executable"}}}
    refute_receive {:frame, %{data: %{text: "environment executable"}}}
  end

  test "rejects an executable whose fingerprint changed before launch" do
    marker =
      Path.join(System.tmp_dir!(), "opencode_changed_#{System.unique_integer([:positive])}")

    path = fake_opencode("printf launched > '#{marker}'")
    {:ok, identity} = Runtime.identify_executable(path)
    File.write!(path, "#!/bin/sh\nprintf changed > '#{marker}'\n")
    File.chmod!(path, 0o700)

    on_exit(fn ->
      File.rm(path)
      File.rm(marker)
    end)

    runtime = %{runtime(path) | executable_identity: identity}

    assert {:error,
            %{
              "category" => "executable_changed",
              "message" => "OpenCode executable changed after discovery",
              "retryable" => false
            }} = OpenCode.stream(runtime, request(), fn _frame -> :ok end)

    refute File.exists?(marker)
  end

  test "assembles a JSON record split across port data messages" do
    path =
      fake_opencode("""
      printf '%s' '{"type":"text","sessionID":"session-1","part":'
      sleep 0.05
      printf '%s\n' '{"text":"partial JSON"}}'
      """)

    test_pid = self()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{session_id: "session-1"}} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "partial JSON"}}}
  end

  test "keeps non-JSON output as diagnostics when the command succeeds" do
    path =
      fake_opencode("""
      printf '%s\n' 'warming provider cache'
      #{json_line("successful response")}
      """)

    test_pid = self()
    on_exit(fn -> File.rm(path) end)

    assert {:ok, _metadata} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "successful response"}}}
  end

  test "returns a protocol error when successful output has no recognized records" do
    path =
      fake_opencode("""
      printf '%s\n' 'warming provider cache'
      printf '%s\n' '{"type":"unknown"}'
      """)

    on_exit(fn -> File.rm(path) end)

    assert {:error,
            %{
              "category" => "protocol_error",
              "message" => "OpenCode exited successfully without recognized protocol records",
              "retryable" => false
            }} = OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)
  end

  test "returns bounded diagnostics for a nonzero exit" do
    path =
      fake_opencode("""
      printf '%s\n' 'authentication failed' >&2
      exit 7
      """)

    previous = Application.get_env(:rey_code, :opencode_max_diagnostic_bytes)
    Application.put_env(:rey_code, :opencode_max_diagnostic_bytes, 10)

    on_exit(fn ->
      restore_env(:opencode_max_diagnostic_bytes, previous)
      File.rm(path)
    end)

    assert {:error,
            %{
              "category" => "command_failed",
              "message" => "authentica\n[diagnostics truncated]",
              "retryable" => false
            }} = OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)
  end

  test "applies one total invocation deadline" do
    path =
      fake_opencode("""
      while true; do
        printf '%s\n' 'still working'
      done
      """)

    previous = Application.get_env(:rey_code, :provider_timeout_ms)
    previous_output = Application.get_env(:rey_code, :opencode_max_output_bytes)
    Application.put_env(:rey_code, :provider_timeout_ms, 60)
    Application.put_env(:rey_code, :opencode_max_output_bytes, 100_000_000)

    on_exit(fn ->
      restore_env(:provider_timeout_ms, previous)
      restore_env(:opencode_max_output_bytes, previous_output)
      File.rm(path)
    end)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %{"category" => "timeout"}} =
             OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)

    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  test "invocation timeout terminates resistant provider descendants" do
    child_pid_path =
      Path.join(System.tmp_dir!(), "rey_code_stream_child_#{System.unique_integer([:positive])}")

    path =
      fake_opencode("""
      /bin/sh -c 'trap "" TERM; echo $$ > "#{child_pid_path}"; while true; do sleep 1; done' &
      while true; do sleep 1; done
      """)

    previous_timeout = Application.get_env(:rey_code, :provider_timeout_ms)
    previous_output = Application.get_env(:rey_code, :opencode_max_output_bytes)
    Application.put_env(:rey_code, :provider_timeout_ms, 1_000)
    Application.put_env(:rey_code, :opencode_max_output_bytes, 1_000_000)

    on_exit(fn ->
      restore_env(:provider_timeout_ms, previous_timeout)
      restore_env(:opencode_max_output_bytes, previous_output)
      File.rm(path)
      File.rm(child_pid_path)
    end)

    assert {:error, %{"category" => "timeout"}} =
             OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)

    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert eventually(fn -> not process_alive?(child_pid) end)
  end

  test "counts newline-free stderr against total output and bounds retained diagnostics" do
    path = fake_opencode("printf '%100s' '' | tr ' ' x >&2\nexit 7")
    previous_output = Application.get_env(:rey_code, :opencode_max_output_bytes)
    previous_diagnostics = Application.get_env(:rey_code, :opencode_max_diagnostic_bytes)

    on_exit(fn ->
      restore_env(:opencode_max_output_bytes, previous_output)
      restore_env(:opencode_max_diagnostic_bytes, previous_diagnostics)
      File.rm(path)
    end)

    Application.put_env(:rey_code, :opencode_max_output_bytes, 50)
    Application.put_env(:rey_code, :opencode_max_diagnostic_bytes, 10)

    assert {:error, %{"category" => "output_too_large"}} =
             OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)

    Application.put_env(:rey_code, :opencode_max_output_bytes, 1_000)

    assert {:error,
            %{
              "category" => "command_failed",
              "message" => "xxxxxxxxxx\n[diagnostics truncated]"
            }} = OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)
  end

  test "coalesces adjacent text records into bounded durable frames" do
    body = Enum.map_join(1..100, "\n", fn _index -> json_line("x") end)
    path = fake_opencode(body)
    previous_bytes = Application.get_env(:rey_code, :opencode_text_chunk_bytes)
    previous_latency = Application.get_env(:rey_code, :opencode_text_chunk_latency_ms)
    test_pid = self()

    on_exit(fn ->
      restore_env(:opencode_text_chunk_bytes, previous_bytes)
      restore_env(:opencode_text_chunk_latency_ms, previous_latency)
      File.rm(path)
    end)

    Application.put_env(:rey_code, :opencode_text_chunk_bytes, 16)
    Application.put_env(:rey_code, :opencode_text_chunk_latency_ms, 60_000)

    assert {:ok, _metadata} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    frames = collect_frames([])
    text_frames = Enum.filter(frames, &(&1.kind == :text_delta))

    assert length(text_frames) == 7
    assert Enum.all?(text_frames, &(byte_size(&1.data.text) <= 16))
    assert Enum.map_join(text_frames, & &1.data.text) == String.duplicate("x", 100)
    assert Enum.map(frames, & &1.sequence) == Enum.to_list(1..8)
  end

  test "rejects an oversized prompt before launching the executable" do
    marker =
      Path.join(System.tmp_dir!(), "opencode_launched_#{System.unique_integer([:positive])}")

    path = fake_opencode("printf launched > '#{marker}'")
    previous = Application.get_env(:rey_code, :opencode_max_prompt_bytes)
    Application.put_env(:rey_code, :opencode_max_prompt_bytes, 10)

    on_exit(fn ->
      restore_env(:opencode_max_prompt_bytes, previous)
      File.rm(path)
      File.rm(marker)
    end)

    assert {:error, %{"category" => "prompt_too_large"}} =
             OpenCode.stream(runtime(path), request(), fn _frame -> :ok end)

    refute File.exists?(marker)
  end

  test "command runner times out and caps output" do
    timeout_path = fake_opencode("sleep 1")
    output_path = fake_opencode("printf '1234567890'")

    on_exit(fn ->
      File.rm(timeout_path)
      File.rm(output_path)
    end)

    assert {:error, :timeout} = Command.run(timeout_path, [], timeout_ms: 20)

    assert {:error, {:output_limit_exceeded, 5}} =
             Command.run(output_path, [], timeout_ms: 5_000, max_output_bytes: 5)
  end

  test "command timeout terminates the provider process group" do
    child_pid_path =
      Path.join(System.tmp_dir!(), "rey_code_child_pid_#{System.unique_integer([:positive])}")

    path =
      fake_opencode("""
      /bin/sh -c 'trap "" TERM; echo $$ > "#{child_pid_path}"; while true; do sleep 1; done' &
      wait
      """)

    on_exit(fn ->
      File.rm(path)
      File.rm(child_pid_path)
    end)

    {wrapper, args, env} = Environment.wrap(path, [], source: System.get_env())
    assert {:error, :timeout} = Command.run(wrapper, args, timeout_ms: 1_000, env: env)

    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert eventually(fn -> not process_alive?(child_pid) end)
  end

  test "waits for stdin to close before reading the prompt" do
    path =
      fake_opencode("""
      cat >/dev/null
      #{json_line("response after stdin EOF")}
      """)

    previous = Application.get_env(:rey_code, :provider_timeout_ms)
    Application.put_env(:rey_code, :provider_timeout_ms, 10_000)
    test_pid = self()

    on_exit(fn ->
      restore_env(:provider_timeout_ms, previous)
      File.rm(path)
    end)

    assert {:ok, %{session_id: "session-1"}} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "response after stdin EOF"}}}
  end

  test "sends the prompt over stdin and keeps it out of process arguments" do
    args_file =
      Path.join(System.tmp_dir!(), "opencode_args_#{System.unique_integer([:positive])}")

    stdin_file =
      Path.join(System.tmp_dir!(), "opencode_stdin_#{System.unique_integer([:positive])}")

    path =
      fake_opencode("""
      printf '%s\\n' "$@" > '#{args_file}'
      cat > '#{stdin_file}'
      #{json_line("stdin received")}
      """)

    on_exit(fn ->
      File.rm(path)
      File.rm(args_file)
      File.rm(stdin_file)
    end)

    assert {:ok, %{session_id: "session-1"}} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(self(), {:frame, frame})
               :ok
             end)

    stdin = File.read!(stdin_file)
    assert stdin =~ "Respond concisely"
    assert stdin =~ "Hello"
    assert stdin =~ "Builder"

    args = File.read!(args_file)
    refute args =~ "Respond concisely"
    assert args =~ "--model"
    assert args =~ "openai/gpt-5.6-sol"
  end

  test "passes only the provider environment allowlist" do
    env_file = Path.join(System.tmp_dir!(), "opencode_env_#{System.unique_integer([:positive])}")
    test_pid = self()
    denied_name = "REY_CODE_DENIED_#{System.unique_integer([:positive])}"
    allowed_name = "REY_CODE_ALLOWED_#{System.unique_integer([:positive])}"
    System.put_env(denied_name, "must-not-leak")
    System.put_env(allowed_name, "configured-value")

    previous = Application.get_env(:rey_code, :opencode_env_allowlist)
    Application.put_env(:rey_code, :opencode_env_allowlist, [allowed_name])

    path =
      fake_opencode("""
      printf '%s\\n' "$PATH" "${#{denied_name}+present}" "${#{allowed_name}}" "$NO_COLOR" > '#{env_file}'
      #{json_line("environment restricted")}
      """)

    on_exit(fn ->
      restore_env(:opencode_env_allowlist, previous)
      System.delete_env(denied_name)
      System.delete_env(allowed_name)
      File.rm(path)
      File.rm(env_file)
    end)

    assert {:ok, _metadata} =
             OpenCode.stream(runtime(path), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "environment restricted"}}}

    assert [path_value, "", "configured-value", "1"] =
             File.read!(env_file) |> String.split("\n", trim: false) |> Enum.drop(-1)

    assert path_value != ""
  end

  defp request do
    %Request{
      invocation_id: "inv-1",
      turn_id: "turn-1",
      room_id: "room-1",
      mode: :compare,
      participant: %{
        id: "builder",
        name: "Builder",
        perspective: "implementation",
        provider: :opencode,
        model: "openai/gpt-5.6-sol"
      },
      system_prompt: "Respond concisely",
      messages: [%{role: :user, content: "Hello", author: %{name: "You"}}],
      workspace: System.tmp_dir!(),
      resume_from: 0
    }
  end

  defp runtime(path) do
    %Runtime{
      module: OpenCode,
      executable: path,
      version: "test",
      models: ["openai/gpt-5.6-sol"],
      status: :configured
    }
  end

  defp json_line(text) do
    "printf '%s\\n' '#{Jason.encode!(%{type: "text", sessionID: "session-1", part: %{text: text}})}'"
  end

  defp fake_opencode(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fake_opencode_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.write!(path, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:rey_code, key)
  defp restore_env(key, value), do: Application.put_env(:rey_code, key, value)

  defp collect_frames(frames) do
    receive do
      {:frame, frame} -> collect_frames([frame | frames])
    after
      0 -> Enum.reverse(frames)
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  defp process_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
