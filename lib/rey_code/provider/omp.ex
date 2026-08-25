defmodule ReyCode.Provider.OMP do
  @moduledoc "OMP RPC coding-agent discovery and invocation adapter."

  @behaviour ReyCode.Provider

  alias ReyCode.Failure
  alias ReyCode.Provider.{Frame, Request, Response, Runtime}
  alias ReyCode.Provider.OMP.{Discovery, Process, Protocol}
  alias ReyCode.Provider.OpenCode.Prompt
  alias ReyCode.Security.Workspace

  @doc "Discovers the OMP executable, version, and available models."
  @spec discover(keyword()) :: {:ok, map()} | {:error, term()}
  def discover(opts \\ []), do: Discovery.discover(opts)

  @doc "Streams one OMP RPC response as provider frames."
  @impl true
  @spec stream(Runtime.t(), Request.t(), (Frame.t() -> :ok)) ::
          {:ok, Response.t()} | {:error, Failure.t()}
  def stream(%Runtime{module: __MODULE__, executable: executable} = runtime, request, emit)
      when is_binary(executable) do
    with {:ok, runtime} <- Runtime.revalidate_executable(runtime),
         {:ok, workspace} <-
           Workspace.validate(request.workspace, policy: runtime.workspace_policy) do
      run(runtime.executable, %{request | workspace: workspace}, emit, runtime.config)
    else
      {:error, {:executable_changed, _details}} ->
        {:error, error(:executable_changed, "OMP executable changed after discovery")}

      {:error, {:executable_unavailable, reason}} ->
        {:error, error(:invalid_executable, "OMP executable is unavailable: #{reason}")}

      {:error, reason} ->
        {:error, error(:invalid_workspace, "OMP workspace is invalid: #{reason}")}
    end
  end

  def stream(%Runtime{}, _request, _emit) do
    {:error, error(:invalid_runtime, "OMP runtime has no executable")}
  end

  defp run(executable, request, emit, config) do
    prompt = Prompt.build(request)

    if byte_size(prompt) > config.max_prompt_bytes do
      {:error,
       error(
         :prompt_too_large,
         "OMP prompt is #{byte_size(prompt)} bytes; maximum is #{config.max_prompt_bytes} bytes"
       )}
    else
      launch(executable, request, prompt, emit, config)
    end
  end

  defp launch(executable, request, prompt, emit, config) do
    input =
      [
        Jason.encode!(%{
          id: "model",
          type: "set_model",
          provider: model_provider(request),
          modelId: model_id(request)
        }),
        Jason.encode!(%{id: "prompt", type: "prompt", message: prompt})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    stream =
      Process.open_stream(
        executable,
        ["--mode", "rpc", "--no-session"],
        request.workspace,
        input,
        Process.environment_opts(config)
      )

    state = Protocol.new(request, config)

    collect_opts = [
      next_deadline: &Protocol.next_flush_deadline/1,
      on_deadline: &Protocol.flush_due(&1, emit, &2)
    ]

    case Process.collect(
           stream,
           &Protocol.fold(&1, &2, emit),
           state,
           config.provider_timeout_ms,
           collect_opts
         ) do
      {:ok, final_state} -> Protocol.finish(final_state)
      {:error, _reason} = error -> error
    end
  end

  defp model_provider(request) do
    request.participant.model
    |> String.split("/", parts: 2)
    |> List.first()
  end

  defp model_id(request) do
    case String.split(request.participant.model, "/", parts: 2) do
      [_provider, model] -> model
      [model] -> model
    end
  end

  defp error(category, message), do: Failure.new(category, message)
end
