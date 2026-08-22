defmodule ReyCode do
  @moduledoc """
  A terminal-native orchestration console for running agent workflows.
  """

  alias ReyCode.Orchestration.Engine

  @doc "Creates a project room rooted at `workspace`."
  @spec create_room(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def create_room(title, workspace \\ File.cwd!()), do: Engine.create_room(title, workspace)

  @doc "Posts a message to a room using the selected orchestration mode."
  @spec post_message(String.t(), String.t(), :compare | :debate | :fan_out | :squad) ::
          {:ok, String.t()} | {:error, term()}
  def post_message(room_id, body, mode \\ :compare) do
    Engine.post_message(room_id, body, mode)
  end

  @doc "Durably cancels a queued or running turn."
  @spec cancel_turn(String.t(), String.t()) :: :ok | {:error, atom()}
  def cancel_turn(turn_id, reason \\ "Cancelled by user") do
    Engine.cancel_turn(turn_id, reason)
  end

  @doc "Adds an owner directive to a running squad turn."
  @spec direct_squad(String.t(), String.t()) :: :ok | {:error, atom()}
  def direct_squad(turn_id, directive) do
    Engine.add_squad_directive(turn_id, directive)
  end

  @doc "Resolves a pending human squad gate review."
  @spec resolve_gate(String.t(), atom() | String.t(), String.t() | nil, [String.t()]) ::
          :ok | {:error, atom()}
  def resolve_gate(turn_id, decision, target_phase \\ nil, reasons \\ []) do
    Engine.resolve_gate(turn_id, decision, target_phase, reasons)
  end

  @doc "Resolves a pending owner approval for a durable tool run."
  @spec resolve_tool_run(String.t(), String.t(), atom() | String.t()) :: :ok | {:error, atom()}
  def resolve_tool_run(invocation_id, run_id, decision) do
    Engine.resolve_tool_run(invocation_id, run_id, decision)
  end

  @doc "Assigns a provider runtime and model to room participants."
  @spec configure_participants(String.t(), [String.t()], atom(), String.t() | nil) ::
          :ok | {:error, atom()}
  def configure_participants(room_id, participant_ids, provider, model \\ nil) do
    Engine.configure_participants(room_id, participant_ids, provider, model)
  end

  @doc "Assigns a provider runtime and model to fixed squad roles."
  @spec configure_squad_roles(String.t(), [String.t()], atom(), String.t() | nil) ::
          :ok | {:error, atom()}
  def configure_squad_roles(room_id, role_ids, provider, model \\ nil) do
    Engine.configure_squad_roles(room_id, role_ids, provider, model)
  end

  @doc "Returns the current projected orchestration state."
  @spec snapshot() :: ReyCode.Orchestration.Projector.state()
  def snapshot, do: Engine.snapshot()
end
