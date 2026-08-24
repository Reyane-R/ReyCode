defmodule ReyCode.Provider.OpenCode do
  @moduledoc "OpenCode CLI discovery and invocation adapter."

  @behaviour ReyCode.Provider

  alias ReyCode.Provider.{Frame, Request, Response, Runtime}
  alias ReyCode.Provider.OpenCode.{Discovery, Process, Prompt, Protocol}
  alias ReyCode.Security.Workspace

  @doc "Discovers the OpenCode executable, version, credentials, and available models."
  @spec discover(keyword()) :: {:ok, map()} | {:error, term()}
  def discover(opts \\ []), do: Discovery.discover(opts)

  @doc "Streams an OpenCode response as provider frames and one text round."
  @impl true
  @spec stream(Runtime.t(), Request.t(), (Frame.t() -> :ok)) ::
          {:ok, Response.t()} | {:error, map()}
  def stream(%Runtime{module: __MODULE__, executable: executable} = runtime, request, emit)
      when is_binary(executable) do
    with {:ok, runtime} <- Runtime.revalidate_executable(runtime),
         {:ok, workspace} <-
           Workspace.validate(request.workspace, policy: runtime.workspace_policy) do
      run(runtime.executable, %{request | workspace: workspace}, emit, runtime.config)
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

  defp run(executable, request, emit, config) do
    prompt = Prompt.build(request)

    max_prompt_bytes = config.max_prompt_bytes

    if byte_size(prompt) > max_prompt_bytes do
      {:error,
       error(
         "prompt_too_large",
         "OpenCode prompt is #{byte_size(prompt)} bytes; maximum is #{max_prompt_bytes} bytes"
       )}
    else
      launch(executable, request, prompt, emit, config)
    end
  end

  defp launch(executable, request, prompt, emit, config) do
    timeout = config.provider_timeout_ms
    state = Protocol.new(request, config)

    args = Process.launch_args(request)

    stream =
      Process.open_stream(
        executable,
        args,
        request.workspace,
        prompt,
        Process.environment_opts(config)
      )

    collect_opts = [
      next_deadline: &Protocol.next_flush_deadline/1,
      on_deadline: &Protocol.flush_due(&1, emit, &2)
    ]

    case Process.collect(stream, &Protocol.fold(&1, &2, emit), state, timeout, collect_opts) do
      {:ok, final_state} ->
        case Protocol.finish(final_state) do
          {:ok, _metadata} -> {:ok, Response.new([])}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp error(category, message) do
    %{"category" => category, "message" => message, "retryable" => false}
  end
end
