defmodule ReyCode.TUI.Blackwall do
  @moduledoc "Transient conversation decoration; never writes to the Projection."

  @breach_ms 600
  @settle_ms 400

  defstruct session_id: nil, work_id: nil, accepted_id: nil, phase: :idle, started_ms: 0

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          work_id: String.t() | nil,
          accepted_id: String.t() | nil,
          phase:
            :idle
            | :breach
            | :waiting
            | :receiving
            | :working
            | :settling
            | :blocked
            | :failed
            | :cancelled,
          started_ms: integer()
        }

  @doc "Reconciles visual transitions using an injected monotonic timestamp."
  @spec reconcile(t(), map(), ReyCode.TUI.Activity.View.t(), integer(), boolean()) :: t()
  def reconcile(previous, assigns, activity, now_ms, motion? \\ true) do
    session_id = assigns.selected_session_id
    session = Map.get(assigns.projection.sessions, session_id)
    work_id = session && session.active_turn_id
    phase = phase(assigns, activity)

    next = %__MODULE__{
      session_id: session_id,
      work_id: work_id,
      phase: phase,
      accepted_id: accepted_message(session, assigns.projection),
      started_ms: now_ms
    }

    if previous.session_id != session_id or assigns.home or not motion?,
      do: quiet(next),
      else: transition(previous, next)
  end

  @doc "Only the finite closing sweep extends the existing activity clock."
  @spec settling?(t()) :: boolean()
  def settling?(%__MODULE__{phase: phase}), do: phase == :settling

  @doc "Finite transitions retain a clock even when execution is blocked."
  @spec transitioning?(t()) :: boolean()
  def transitioning?(%__MODULE__{phase: phase}), do: phase in [:breach, :settling]

  @spec animated?(t()) :: boolean()
  def animated?(%__MODULE__{phase: phase}),
    do: phase in [:breach, :waiting, :receiving, :working, :settling]

  @spec color(t()) :: String.t()
  def color(%__MODULE__{phase: :receiving}), do: "primary"
  def color(%__MODULE__{phase: :blocked}), do: "warning"
  def color(%__MODULE__{phase: :failed}), do: "error"
  def color(%__MODULE__{phase: phase}) when phase in [:idle, :cancelled], do: "boundary"
  def color(_state), do: "accent"

  @doc "Shared duration for the lifecycle and renderer closing sweep."
  @spec settle_ms() :: pos_integer()
  def settle_ms, do: @settle_ms

  defp transition(previous, next) do
    cond do
      new_work?(previous, next) -> %{next | phase: :breach}
      holding?(previous, next) -> previous
      closing?(previous, next) -> %{next | phase: :settling}
      {previous.phase, previous.work_id} == {quiet(next).phase, next.work_id} -> previous
      true -> quiet(next)
    end
  end

  defp new_work?(previous, %{accepted_id: id}) when not is_nil(id),
    do: previous.accepted_id != id

  defp new_work?(_previous, _next), do: false

  defp holding?(%{phase: :breach} = previous, %{phase: phase} = next)
       when phase in [:waiting, :working, :idle, :blocked],
       do: next.started_ms - previous.started_ms < @breach_ms

  defp holding?(%{phase: :settling} = previous, %{phase: :completed} = next),
    do: next.started_ms - previous.started_ms < @settle_ms

  defp holding?(_previous, _next), do: false

  defp closing?(previous, %{phase: :completed}),
    do: previous.phase in [:breach, :waiting, :receiving, :working]

  defp closing?(_previous, _next), do: false

  defp quiet(%{phase: :completed} = state), do: %{state | phase: :idle}
  defp quiet(state), do: state

  defp accepted_message(nil, _projection), do: nil

  defp accepted_message(session, projection) do
    Enum.find_value(session.message_order, fn id ->
      case Map.get(projection.messages, id) do
        %{role: :user} -> id
        _ -> nil
      end
    end)
  end

  defp phase(%{home: true}, _activity), do: :idle
  defp phase(_assigns, %{header: %{state: :blocked}}), do: :blocked
  defp phase(_assigns, %{header: %{outcome: :failed}}), do: :failed
  defp phase(_assigns, %{header: %{outcome: :cancelled}}), do: :cancelled

  defp phase(_assigns, %{header: %{state: :terminal, outcome: outcome}})
       when outcome in [:completed, :reworked], do: :completed

  defp phase(_assigns, %{header: %{kind: :tool, active?: true}}), do: :working

  defp phase(assigns, %{header: %{kind: :invocation, id: id, active?: true}}) do
    invocation = Map.get(assigns.projection.invocations, id)
    message = invocation && Map.get(assigns.projection.messages, invocation.message_id)
    if message && message.body != "", do: :receiving, else: :waiting
  end

  defp phase(_assigns, %{header: %{kind: :delegation, active?: true}}), do: :working
  defp phase(_assigns, %{header: %{state: :queued}}), do: :waiting
  defp phase(_assigns, _activity), do: :idle
end
