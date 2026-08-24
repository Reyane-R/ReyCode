defmodule ReyCode.Provider.OpenCode.ProcessTest do
  use ExUnit.Case, async: false

  import ReyCode.Test.OpenCodeHelpers,
    only: [
      eventually: 1,
      eventually: 2,
      fake_opencode: 1,
      json_line: 1,
      process_alive?: 1,
      request: 0,
      restore_env: 2,
      runtime: 1,
      runtime: 2
    ]

  alias ReyCode.Provider.{Command, OpenCode, Runtime}
  alias ReyCode.Provider.OpenCode.Process
  alias ReyCode.Security.Environment

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
      printf '%s\\n' "$PWD" > '#{capture_path}'
      printf '%s\\n' "$@" > '#{args_path}'
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

  test "streams with the runtime's frozen policy even when ambient policy disagrees" do
    discovered = fake_opencode(json_line("frozen policy"))
    test_pid = self()

    # Ambient application policy would reject this prompt outright; the
    # runtime's injected config must win because providers never read the
    # environment.
    previous = Application.get_env(:rey_code, :opencode_max_prompt_bytes)
    Application.put_env(:rey_code, :opencode_max_prompt_bytes, 10)

    on_exit(fn ->
      restore_env(:opencode_max_prompt_bytes, previous)
      File.rm(discovered)
    end)

    assert {:ok, _metadata} =
             OpenCode.stream(runtime(discovered), request(), fn frame ->
               send(test_pid, {:frame, frame})
               :ok
             end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "frozen policy"}}}
  end

  test "flushes a short text delta while OpenCode remains silent" do
    path =
      fake_opencode("""
      #{json_line("latency bounded")}
      sleep 2
      """)

    test_pid = self()

    task =
      Task.async(fn ->
        OpenCode.stream(
          runtime(path,
            provider_timeout_ms: 5_000,
            opencode_text_chunk_bytes: 1_000,
            opencode_text_chunk_latency_ms: 50
          ),
          request(),
          fn frame ->
            send(test_pid, {:frame, frame})
            :ok
          end
        )
      end)

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "latency bounded"}}}, 3_000
    assert Task.yield(task, 0) == nil
    assert {:ok, _response} = Task.await(task, 5_000)
    refute_receive {:frame, %{kind: :text_delta, data: %{text: "latency bounded"}}}

    on_exit(fn -> File.rm(path) end)
  end

  test "total deadline bounds a slow reducer" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, %{"category" => "timeout"}} =
             Process.collect(
               [:item],
               fn _item, acc ->
                 Elixir.Process.sleep(500)
                 {:cont, acc}
               end,
               :ok,
               50
             )

    assert System.monotonic_time(:millisecond) - started_at < 300
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

  test "applies one total invocation deadline" do
    path =
      fake_opencode("""
      while true; do
        printf '%s\\n' 'still working'
      done
      """)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %{"category" => "timeout"}} =
             OpenCode.stream(
               runtime(path, provider_timeout_ms: 60, opencode_max_output_bytes: 100_000_000),
               request(),
               fn _frame -> :ok end
             )

    assert System.monotonic_time(:millisecond) - started_at < 500

    on_exit(fn -> File.rm(path) end)
  end

  test "invocation timeout terminates resistant provider descendants" do
    child_pid_path =
      Path.join(System.tmp_dir!(), "rey_code_stream_child_#{System.unique_integer([:positive])}")

    path =
      fake_opencode("""
      /bin/sh -c 'trap "" TERM; echo $$ > "#{child_pid_path}"; while true; do sleep 1; done' &
      while true; do sleep 1; done
      """)

    task =
      Task.async(fn ->
        OpenCode.stream(
          runtime(path, provider_timeout_ms: 10_000, opencode_max_output_bytes: 1_000_000),
          request(),
          fn _frame -> :ok end
        )
      end)

    assert eventually(fn -> File.exists?(child_pid_path) end, 100)
    assert {:error, %{"category" => "timeout"}} = Task.await(task, 15_000)
    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert eventually(fn -> not process_alive?(child_pid) end)

    on_exit(fn ->
      File.rm(path)
      File.rm(child_pid_path)
    end)
  end

  test "rejects an oversized prompt before launching the executable" do
    marker =
      Path.join(System.tmp_dir!(), "opencode_launched_#{System.unique_integer([:positive])}")

    path = fake_opencode("printf launched > '#{marker}'")

    assert {:error, %{"category" => "prompt_too_large"}} =
             OpenCode.stream(runtime(path, opencode_max_prompt_bytes: 10), request(), fn _frame ->
               :ok
             end)

    refute File.exists?(marker)

    on_exit(fn ->
      File.rm(path)
      File.rm(marker)
    end)
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
    assert {:error, :timeout} = Command.run(wrapper, args, timeout_ms: 3_000, env: env)

    child_pid = child_pid_path |> File.read!() |> String.trim()
    assert eventually(fn -> not process_alive?(child_pid) end, 40)
  end

  test "waits for stdin to close before reading the prompt" do
    path =
      fake_opencode("""
      cat >/dev/null
      #{json_line("response after stdin EOF")}
      """)

    test_pid = self()

    assert {:ok, %{}} =
             OpenCode.stream(
               runtime(path, provider_timeout_ms: 10_000),
               request(),
               fn frame ->
                 send(test_pid, {:frame, frame})
                 :ok
               end
             )

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "response after stdin EOF"}}}

    on_exit(fn -> File.rm(path) end)
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

    assert {:ok, %{}} =
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
    env_file =
      Path.join(System.tmp_dir!(), "opencode_env_#{System.unique_integer([:positive])}")

    test_pid = self()
    denied_name = "REY_CODE_DENIED_#{System.unique_integer([:positive])}"
    allowed_name = "REY_CODE_ALLOWED_#{System.unique_integer([:positive])}"
    System.put_env(denied_name, "must-not-leak")
    System.put_env(allowed_name, "configured-value")

    path =
      fake_opencode("""
      printf '%s\\n' "$PATH" "${#{denied_name}+present}" "${#{allowed_name}}" "$NO_COLOR" > '#{env_file}'
      #{json_line("environment restricted")}
      """)

    on_exit(fn ->
      System.delete_env(denied_name)
      System.delete_env(allowed_name)
      File.rm(path)
      File.rm(env_file)
    end)

    assert {:ok, _metadata} =
             OpenCode.stream(
               runtime(path, opencode_env_allowlist: [allowed_name]),
               request(),
               fn frame ->
                 send(test_pid, {:frame, frame})
                 :ok
               end
             )

    assert_receive {:frame, %{kind: :text_delta, data: %{text: "environment restricted"}}}

    assert [path_value, "", "configured-value", "1"] =
             File.read!(env_file) |> String.split("\n", trim: false) |> Enum.drop(-1)

    assert path_value != ""
  end

  describe "collect/4 task failures" do
    test "maps a raising stream to a launch failure" do
      stream = Stream.map([:only], fn _ -> raise "stream exploded" end)

      assert {:error, %{"category" => "launch_failed", "message" => "stream exploded"}} =
               Process.collect(stream, fn _, acc -> {:cont, acc} end, :ok, 5_000)
    end

    test "maps a throwing stream to a launch failure" do
      stream = Stream.map([:only], fn _ -> throw(:thrown) end)

      assert {:error, %{"category" => "launch_failed", "message" => message}} =
               Process.collect(stream, fn _, acc -> {:cont, acc} end, :ok, 5_000)

      assert message =~ ":thrown"
    end

    test "maps an unfinished stream to a timeout" do
      assert {:error, %{"category" => "timeout", "message" => message}} =
               Process.collect(
                 Stream.cycle([:tick]),
                 fn _, acc -> {:cont, acc} end,
                 :ok,
                 50
               )

      assert message =~ "did not finish within 50ms"
    end
  end
end
