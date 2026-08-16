defmodule ReyCode.Orchestration.Engine.Client do
  @moduledoc "Internal process protocol used by supervised invocation workers."

  alias ReyCode.Provider.Frame

  @spec invocation_request(GenServer.server(), String.t()) :: term()
  def invocation_request(server, invocation_id) do
    GenServer.call(server, {:invocation_request, invocation_id})
  end

  @spec invocation_started(GenServer.server(), String.t()) :: :ok
  def invocation_started(server, invocation_id) do
    GenServer.call(server, {:invocation_started, invocation_id})
  end

  @spec record_frame(GenServer.server(), String.t(), Frame.t()) :: :ok | {:error, term()}
  def record_frame(server, invocation_id, %Frame{} = frame) do
    GenServer.call(server, {:record_frame, invocation_id, frame}, :infinity)
  end

  @spec complete_invocation(GenServer.server(), String.t(), map()) :: :ok
  def complete_invocation(server, invocation_id, metadata) do
    GenServer.call(server, {:complete_invocation, invocation_id, metadata}, :infinity)
  end

  @spec fail_invocation(GenServer.server(), String.t(), map()) :: :ok
  def fail_invocation(server, invocation_id, error) do
    GenServer.call(server, {:fail_invocation, invocation_id, error}, :infinity)
  end
end
