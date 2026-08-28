defmodule ReyCode do
  @moduledoc """
  A terminal-native orchestration console for running agent workflows.
  """

  alias ReyCode.Orchestration.Engine

  @doc "Creates a blank durable session rooted at `workspace`."
  @spec create_blank_session(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def create_blank_session(title, workspace \\ File.cwd!()),
    do: Engine.create_blank_session(title, workspace)

  @mode_ids ReyCode.Orchestration.Mode.ids()
            |> Enum.reduce(fn id, union -> {:|, [], [id, union]} end)

  @doc "Posts an ordinary message to the session's primary assistant."
  @spec post_message(String.t(), String.t(), unquote(@mode_ids)) ::
          {:ok, String.t()} | {:error, term()}
  def post_message(session_id, body, mode \\ :direct) do
    Engine.post_message(session_id, body, mode)
  end

  @doc "Creates a durable task-agent profile in a session."
  @spec create_agent(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def create_agent(session_id, name, responsibility) do
    Engine.add_task_participant(session_id, name, responsibility)
  end

  @doc "Delegates one task to one user-created task agent."
  @spec delegate_task(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def delegate_task(session_id, participant_id, task) do
    Engine.delegate_task(session_id, participant_id, task)
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

  @doc "Resolves a pending human squad gate review by its review id."
  @spec resolve_gate(String.t(), String.t() | nil, atom() | String.t(), String.t() | nil, [
          String.t()
        ]) :: :ok | {:error, atom()}
  def resolve_gate(turn_id, review_id, decision, target_phase \\ nil, reasons \\ []) do
    Engine.resolve_gate(turn_id, review_id, decision, target_phase, reasons)
  end

  @doc "Resolves a pending owner approval for a durable tool run."
  @spec resolve_tool_run(String.t(), String.t(), atom() | String.t()) :: :ok | {:error, atom()}
  def resolve_tool_run(invocation_id, run_id, decision) do
    Engine.resolve_tool_run(invocation_id, run_id, decision)
  end

  @doc "Assigns a provider runtime and model to session participants."
  @spec configure_participants(String.t(), [String.t()], atom(), String.t() | nil) ::
          :ok | {:error, atom()}
  def configure_participants(session_id, participant_ids, provider, model \\ nil) do
    Engine.configure_participants(session_id, participant_ids, provider, model)
  end

  @doc "Assigns a provider runtime and model to fixed squad roles."
  @spec configure_squad_roles(String.t(), [String.t()], atom(), String.t() | nil) ::
          :ok | {:error, atom()}
  def configure_squad_roles(session_id, role_ids, provider, model \\ nil) do
    Engine.configure_squad_roles(session_id, role_ids, provider, model)
  end

  @doc "Returns the current projected orchestration state."
  @spec snapshot() :: ReyCode.Orchestration.Projector.state()
  def snapshot, do: Engine.snapshot()
end
