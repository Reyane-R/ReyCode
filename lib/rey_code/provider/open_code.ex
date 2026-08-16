defmodule ReyCode.Provider.OpenCode do
  @moduledoc "OpenCode CLI discovery and invocation adapter."

  @behaviour ReyCode.Provider

  alias ReyCode.Provider.OpenCode.{Discovery, Process, Prompt, Protocol}
  alias ReyCode.Provider.{Request, Runtime}
  alias ReyCode.Security.Workspace

  @default_prompt_bytes 128_000

  @doc "Discovers the OpenCode executable, version, credentials, and available models."
  @spec discover(keyword()) :: {:ok, map()} | {:error, term()}
  def discover(opts \\ []), do: Discovery.discover(opts)

  @doc "Streams an OpenCode response as provider frames."
  @impl true
  @spec stream(Runtime.t(), Request.t(), ReyCode.Provider.emit()) ::
          {:ok, map()} | {:error, map()}
  def stream(%Runtime{module: __MODULE__, executable: executable} = runtime, request, emit)
      when is_binary(executable) do
    with {:ok, runtime} <- Runtime.revalidate_executable(runtime),
         {:ok, workspace} <- Workspace.validate(request.workspace) do
      run(runtime.executable, %{request | workspace: workspace}, emit)
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

  defp run(executable, request, emit) do
    prompt = Prompt.build(request)

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
    state = Protocol.new(request)
    args = Process.launch_args(request)
    stream = Process.open_stream(executable, args, request.workspace, prompt)

    case Process.collect(stream, &Protocol.fold(&1, &2, emit), state, timeout) do
      {:ok, final_state} -> Protocol.finish(final_state)
      {:error, _reason} = error -> error
    end
  end

  defp error(category, message) do
    %{"category" => category, "message" => message, "retryable" => false}
  end
end
