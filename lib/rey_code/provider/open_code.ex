defmodule ReyCode.Provider.OpenCode do
  @moduledoc "OpenCode CLI discovery and invocation adapter."

  @behaviour ReyCode.Provider

  alias ReyCode.Provider.{Command, Frame, Runtime, TextBuffer}
  alias ReyCode.Security.{Environment, Workspace}

  require Logger

  @ansi ~r/\e\[[0-?]*[ -\/]*[@-~]/
  @model ~r/^[^\s\/]+\/.+$/
  @default_discovery_timeout_ms 5_000
  @default_discovery_output_bytes 256_000
  @default_diagnostic_bytes 64_000
  @default_output_bytes 10_000_000
  @default_prompt_bytes 128_000
  @default_text_chunk_bytes 8_192
  @default_text_chunk_latency_ms 50

  @doc "Discovers the OpenCode executable, version, credentials, and available models."
  @spec discover(keyword()) :: {:ok, map()} | {:error, term()}
  def discover(opts \\ []) do
    executable = discovery_executable(opts)
    {executable, executable_identity} = executable_details(executable)
    environment_opts = provider_environment_opts()
    runner = discovery_runner(opts, environment_opts)
    command_opts = discovery_command_opts(opts, environment_opts)

    discover_provider(executable, executable_identity, runner, command_opts)
  end

  defp discovery_executable(opts) do
    Keyword.get(opts, :executable) ||
      Application.get_env(:rey_code, :opencode_path) ||
      System.find_executable("opencode")
  end

  defp discovery_runner(opts, environment_opts) do
    Keyword.get_lazy(opts, :runner, fn ->
      fn executable, args, command_opts ->
        {wrapper, wrapped_args, env} = Environment.wrap(executable, args, environment_opts)
        Command.run(wrapper, wrapped_args, Keyword.put(command_opts, :env, env))
      end
    end)
  end

  defp discovery_command_opts(opts, environment_opts) do
    [
      env: Environment.launch_env(environment_opts),
      timeout_ms:
        Keyword.get(
          opts,
          :timeout_ms,
          Application.get_env(
            :rey_code,
            :provider_discovery_command_timeout_ms,
            @default_discovery_timeout_ms
          )
        ),
      max_output_bytes:
        Keyword.get(
          opts,
          :max_output_bytes,
          Application.get_env(
            :rey_code,
            :provider_discovery_output_bytes,
            @default_discovery_output_bytes
          )
        )
    ]
  end

  defp discover_provider(executable, executable_identity, runner, command_opts) do
    with executable when is_binary(executable) <- executable,
         {:ok, models} <- runner.(executable, ["models"], command_opts) do
      discovery_metadata(executable, executable_identity, models, runner, command_opts)
    else
      nil -> {:error, :missing_executable}
      {:error, reason} -> {:error, command_error(reason)}
    end
  end

  defp discovery_metadata(executable, executable_identity, models, runner, command_opts) do
    version_task =
      Task.async(fn -> safe_run(runner, executable, ["--version"], command_opts) end)

    auth_task =
      Task.async(fn -> safe_run(runner, executable, ["auth", "list"], command_opts) end)

    {:ok,
     %{
       executable: executable,
       executable_identity: executable_identity,
       version: discovery_version(version_task),
       credential_count: discovery_credential_count(auth_task),
       models: parse_models(models)
     }}
  end

  defp discovery_version(task) do
    case Task.await(task, :infinity) do
      {:ok, output} -> String.trim(strip_ansi(output))
      {:error, _reason} -> "unknown"
    end
  end

  defp discovery_credential_count(task) do
    case Task.await(task, :infinity) do
      {:ok, output} -> credential_count(output)
      {:error, _reason} -> 0
    end
  end

  defp safe_run(runner, executable, args, opts) do
    runner.(executable, args, opts)
  rescue
    error ->
      detail = Exception.message(error)
      Logger.warning("OpenCode metadata command failed: #{detail}")
      {:error, {:metadata_unavailable, detail}}
  catch
    kind, reason ->
      Logger.warning("OpenCode metadata command #{kind}: #{inspect(reason)}")
      {:error, {:metadata_unavailable, {kind, reason}}}
  end

  @doc "Streams an OpenCode response as provider frames."
  @impl true
  @spec stream(Runtime.t(), ReyCode.Provider.Request.t(), ReyCode.Provider.emit()) ::
          {:ok, map()} | {:error, map()}
  def stream(%Runtime{module: __MODULE__, executable: executable} = runtime, request, emit)
      when is_binary(executable) do
    with {:ok, runtime} <- Runtime.revalidate_executable(runtime),
         {:ok, workspace} <- Workspace.validate(request.workspace) do
      run_stream(runtime.executable, Map.put(request, :workspace, workspace), emit)
    else
      {:error, {:executable_changed, _details}} ->
        {:error, error("executable_changed", "OpenCode executable changed after discovery")}

      {:error, {:executable_unavailable, reason}} ->
        {:error, error("invalid_executable", "OpenCode executable is unavailable: #{reason}")}

      {:error, reason} ->
        {:error, error("invalid_workspace", "OpenCode workspace is invalid: #{reason}")}
    end
  end

  def stream(%Runtime{}, _request, _emit) do
    {:error, error("invalid_runtime", "OpenCode runtime has no executable")}
  end

  @spec parse_models(binary()) :: [String.t()]
  def parse_models(output) do
    output
    |> strip_ansi()
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(@model, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec credential_count(binary()) :: non_neg_integer()
  def credential_count(output) do
    case Regex.run(~r/(\d+) credentials?/, strip_ansi(output), capture: :all_but_first) do
      [count] -> String.to_integer(count)
      _ -> 0
    end
  end

  @spec parse_line(binary()) :: {:ok, map()} | :ignore
  def parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> :ignore
    end
  end

  defp run_stream(executable, request, emit) do
    prompt = prompt(request)

    max_prompt_bytes =
      Application.get_env(:rey_code, :opencode_max_prompt_bytes, @default_prompt_bytes)

    if byte_size(prompt) > max_prompt_bytes do
      {:error,
       error(
         "prompt_too_large",
         "OpenCode prompt is #{byte_size(prompt)} bytes; maximum is #{max_prompt_bytes} bytes"
       )}
    else
      launch(executable, request, prompt, emit)
    end
  end

  defp launch(executable, request, prompt, emit) do
    timeout = Application.get_env(:rey_code, :provider_timeout_ms, :timer.minutes(10))
    args = launch_args(request)
    state = initial_stream_state()
    stream = open_stream(executable, args, request.workspace, prompt)
    task = collect_stream_task(stream, state, emit)

    await_stream_task(task, timeout)
  end

  defp launch_args(request) do
    [
      "run",
      "--format",
      "json",
      "--model",
      request.participant.model,
      "--dir",
      request.workspace
    ]
  end

  defp initial_stream_state do
    diagnostic_limit =
      Application.get_env(:rey_code, :opencode_max_diagnostic_bytes, @default_diagnostic_bytes)

    %{
      buffer: "",
      stderr_buffer: "",
      text_buffer:
        TextBuffer.new(
          chunk_bytes:
            Application.get_env(
              :rey_code,
              :opencode_text_chunk_bytes,
              @default_text_chunk_bytes
            ),
          chunk_latency_ms:
            Application.get_env(
              :rey_code,
              :opencode_text_chunk_latency_ms,
              @default_text_chunk_latency_ms
            )
        ),
      sequence: 0,
      session_id: nil,
      provider_errors: [],
      diagnostics: [],
      diagnostic_bytes: 0,
      diagnostics_truncated?: false,
      diagnostic_limit: diagnostic_limit,
      output_bytes: 0,
      output_limit:
        Application.get_env(:rey_code, :opencode_max_output_bytes, @default_output_bytes),
      output_limit_exceeded?: false,
      protocol_activity?: false,
      exit_status: nil
    }
  end

  defp open_stream(executable, args, workspace, prompt) do
    {wrapper, wrapped_args, env} =
      Environment.wrap(executable, args, provider_environment_opts())

    exile_stream([wrapper | wrapped_args],
      input: [prompt],
      stderr: :consume,
      ignore_epipe: true,
      exit_timeout: 1_000,
      max_chunk_size: 65_535,
      cd: workspace,
      env: env
    )
  end

  defp collect_stream_task(stream, state, emit) do
    Task.async(fn ->
      try do
        {:ok,
         Enum.reduce_while(stream, state, fn element, acc ->
           collect_element(element, acc, emit)
         end)}
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, reason -> {:error, Exception.format_banner(kind, reason)}
      end
    end)
  end

  defp await_stream_task(task, timeout) do
    case Task.yield(task, timeout) do
      {:ok, {:ok, final_state}} ->
        finish(final_state)

      {:ok, {:error, message}} ->
        {:error, error("launch_failed", message)}

      {:exit, reason} ->
        {:error, error("launch_failed", inspect(reason))}

      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, error("timeout", "OpenCode did not finish within #{timeout}ms")}
    end
  catch
    kind, reason ->
      {:error, error("launch_failed", Exception.format_banner(kind, reason))}
  end

  defp collect_element({:exit, {:status, status}}, state, emit) do
    state = flush_buffers(state, emit)
    {:halt, %{state | exit_status: status}}
  end

  defp collect_element({:exit, other}, state, emit) do
    state = flush_buffers(state, emit)
    {:halt, %{state | exit_status: other}}
  end

  defp collect_element({:stdout, data}, state, emit) do
    output_bytes = state.output_bytes + byte_size(data)

    if output_bytes > state.output_limit do
      {:halt, %{state | output_bytes: output_bytes, output_limit_exceeded?: true}}
    else
      {:cont, consume(state.buffer <> data, %{state | output_bytes: output_bytes}, emit)}
    end
  end

  defp collect_element({:stderr, data}, state, _emit) do
    output_bytes = state.output_bytes + byte_size(data)

    if output_bytes > state.output_limit do
      {:halt, %{state | output_bytes: output_bytes, output_limit_exceeded?: true}}
    else
      {:cont, consume_stderr(data, %{state | output_bytes: output_bytes})}
    end
  end

  defp consume_stderr(data, state) do
    parts = String.split(state.stderr_buffer <> data, "\n")
    rest = List.last(parts) || ""

    state =
      parts
      |> Enum.drop(-1)
      |> Enum.reduce(state, fn line, acc -> append_diagnostic(acc, line) end)

    available = max(state.diagnostic_limit - state.diagnostic_bytes, 0)
    kept = TextBuffer.truncate_utf8(rest, available)

    %{
      state
      | stderr_buffer: kept,
        diagnostics_truncated?: state.diagnostics_truncated? or byte_size(kept) < byte_size(rest)
    }
  end

  defp flush_buffers(%{buffer: stdout_buffer, stderr_buffer: stderr_buffer} = state, emit) do
    state =
      if stdout_buffer == "" do
        state
      else
        consume(stdout_buffer <> "\n", %{state | buffer: ""}, emit)
      end

    state = %{state | stderr_buffer: ""}
    state = if stderr_buffer == "", do: state, else: append_diagnostic(state, stderr_buffer)
    flush_pending_text(state, emit)
  end

  defp finish(%{output_limit_exceeded?: true} = state) do
    {:error, error("output_too_large", "OpenCode output exceeded #{state.output_limit} bytes")}
  end

  defp finish(state) do
    cond do
      state.exit_status not in [nil, 0] ->
        message = failure_diagnostics(state, state.exit_status)
        {:error, error("command_failed", message)}

      state.provider_errors != [] ->
        {:error,
         error("provider_error", state.provider_errors |> Enum.reverse() |> Enum.join("\n"))}

      not state.protocol_activity? ->
        {:error,
         error(
           "protocol_error",
           "OpenCode exited successfully without recognized protocol records"
         )}

      true ->
        {:ok, %{session_id: state.session_id}}
    end
  end

  defp provider_environment_opts do
    [
      source: System.get_env(),
      additional_names: Application.get_env(:rey_code, :opencode_env_allowlist, []),
      cpu_seconds: Application.get_env(:rey_code, :opencode_cpu_seconds, 900),
      open_files: Application.get_env(:rey_code, :opencode_open_files, 1_024)
    ]
  end

  defp executable_details(nil), do: {nil, nil}

  defp executable_details(executable) do
    case Runtime.identify_executable(executable) do
      {:ok, identity} -> {identity.path, identity}
      {:error, _reason} -> {executable, nil}
    end
  end

  defp exile_stream(args, opts) do
    module = Exile
    module.stream(args, opts)
  end

  defp consume(data, state, emit) do
    parts = String.split(data, "\n")
    rest = List.last(parts) || ""

    state =
      parts
      |> Enum.drop(-1)
      |> Enum.reduce(state, fn line, acc -> handle_line(line, acc, emit) end)

    %{state | buffer: rest}
  end

  defp handle_line(line, state, emit) do
    case parse_line(line) do
      {:ok, record} -> handle_record(record, state, emit)
      :ignore -> append_diagnostic(state, line)
    end
  end

  defp handle_record(record, state, emit) do
    state = maybe_emit_session(record["sessionID"], state, emit)

    case record do
      %{"type" => "text", "part" => %{"text" => text}} when is_binary(text) ->
        buffer_text(state, text, emit)

      %{"type" => "tool_use", "part" => part} ->
        state
        |> flush_pending_text(emit)
        |> emit_frame(emit, :tool_completed, %{tool: part["tool"], state: part["state"]})

      %{"type" => "step_finish", "part" => part} ->
        state
        |> flush_pending_text(emit)
        |> emit_frame(emit, :usage, %{usage: %{tokens: part["tokens"], cost: part["cost"]}})

      %{"type" => "error", "error" => value} ->
        state = flush_pending_text(state, emit)

        %{
          state
          | provider_errors: [error_text(value) | state.provider_errors],
            protocol_activity?: true
        }

      _ ->
        state
    end
  end

  defp maybe_emit_session(nil, state, _emit), do: state
  defp maybe_emit_session(session_id, %{session_id: session_id} = state, _emit), do: state

  defp maybe_emit_session(session_id, state, emit) do
    state
    |> flush_pending_text(emit)
    |> Map.put(:session_id, session_id)
    |> emit_frame(emit, :session_started, %{session_id: session_id})
  end

  defp buffer_text(state, "", _emit), do: %{state | protocol_activity?: true}

  defp buffer_text(state, text, emit) do
    {chunks, buffer} = TextBuffer.append(state.text_buffer, text)

    state
    |> Map.put(:text_buffer, buffer)
    |> Map.put(:protocol_activity?, true)
    |> emit_text_chunks(chunks, emit)
  end

  defp flush_pending_text(state, emit) do
    {chunks, buffer} = TextBuffer.flush(state.text_buffer)
    state |> Map.put(:text_buffer, buffer) |> emit_text_chunks(chunks, emit)
  end

  defp emit_text_chunks(state, chunks, emit),
    do: Enum.reduce(chunks, state, &emit_frame(&2, emit, :text_delta, %{text: &1}))

  defp emit_frame(state, emit, kind, data) do
    sequence = state.sequence + 1
    :ok = emit.(%Frame{sequence: sequence, kind: kind, data: data})
    %{state | sequence: sequence, protocol_activity?: true}
  end

  defp append_diagnostic(state, line) do
    line = line |> strip_ansi() |> String.trim()

    cond do
      line == "" ->
        state

      state.diagnostic_bytes >= state.diagnostic_limit ->
        %{state | diagnostics_truncated?: true}

      true ->
        separator_bytes = if state.diagnostics == [], do: 0, else: 1
        available = state.diagnostic_limit - state.diagnostic_bytes - separator_bytes

        if available <= 0 do
          %{state | diagnostics_truncated?: true}
        else
          kept = TextBuffer.truncate_utf8(line, available)

          %{
            state
            | diagnostics: [kept | state.diagnostics],
              diagnostic_bytes: state.diagnostic_bytes + separator_bytes + byte_size(kept),
              diagnostics_truncated?:
                state.diagnostics_truncated? or byte_size(kept) < byte_size(line)
          }
        end
    end
  end

  defp failure_diagnostics(state, status) do
    messages = Enum.reverse(state.provider_errors) ++ Enum.reverse(state.diagnostics)
    message = messages |> Enum.join("\n") |> String.trim()

    message =
      if state.diagnostics_truncated? do
        String.trim(message <> "\n[diagnostics truncated]")
      else
        message
      end

    if message == "", do: "OpenCode exited with status #{status}", else: message
  end

  defp prompt(request) do
    history =
      Enum.map_join(request.messages, "\n\n", fn message ->
        name = get_in(message, [:author, :name]) || Atom.to_string(message.role)
        "#{name}: #{message.content}"
      end)

    [
      request.system_prompt,
      "You are responding as #{request.participant.name} with the perspective: #{request.participant.perspective}.",
      "Conversation context:\n#{history}",
      "Respond to the latest user request."
    ]
    |> Enum.join("\n\n")
  end

  defp command_error(:timeout), do: :command_timeout

  defp command_error({:exit_status, status, output}) do
    output = output |> strip_ansi() |> String.trim()
    if output == "", do: "command exited with status #{status}", else: output
  end

  defp command_error({:output_limit_exceeded, limit}),
    do: "command output exceeded #{limit} bytes"

  defp command_error({:launch_failed, message}), do: message
  defp command_error(reason), do: reason

  defp strip_ansi(value), do: Regex.replace(@ansi, value, "")

  defp error_text(value) when is_binary(value), do: value
  defp error_text(%{"data" => %{"message" => message}}), do: message
  defp error_text(value), do: inspect(value)

  defp error(category, message) do
    %{"category" => category, "message" => message, "retryable" => false}
  end
end
