defmodule ReyCode.Orchestration.Squad.Dashboard do
  @moduledoc "Pure read model and presentation values for the squad dashboard."

  alias ReyCode.Orchestration.{Projection, Room, Squad, Turn}
  alias ReyCode.Orchestration.Squad.{GateResolution, GateReview}

  @type usage_summary :: %{
          tokens: integer(),
          cost: number(),
          cost_known?: boolean(),
          invocations: non_neg_integer()
        }

  @doc "Builds dashboard data for the active or most recent squad turn in a room."
  @spec data(Room.t(), Projection.t()) :: map() | nil
  def data(room, projection) do
    case turn(room, projection) do
      nil ->
        nil

      turn ->
        %{
          turn: turn,
          phases: Enum.with_index(Squad.phases()),
          resolutions: Enum.reverse(turn.squad.resolutions),
          reviews: Enum.reverse(turn.squad.reviews),
          artifacts: Enum.reverse(turn.squad.artifacts),
          retries: Enum.reverse(turn.squad.retries),
          directives: Enum.reverse(turn.squad.directives),
          usage: summarize_usage(turn, projection)
        }
    end
  end

  @doc "Returns the active squad turn, falling back to the room's most recent one."
  @spec turn(Room.t(), Projection.t()) :: Turn.t() | nil
  def turn(room, projection) do
    active = projection.turns[room.active_turn_id]

    if squad_turn?(active) do
      active
    else
      projection.turns
      |> Map.values()
      |> Enum.filter(&(&1.room_id == room.id and squad_turn?(&1)))
      |> Enum.max_by(&Map.get(&1, :created_at, ""), fn -> nil end)
    end
  end

  @doc "Checks whether a projected turn contains squad workflow state."
  @spec squad_turn?(Turn.t() | nil) :: boolean()
  def squad_turn?(%{mode: :squad, squad: squad}) when not is_nil(squad), do: true
  def squad_turn?(_turn), do: false

  @doc "Returns the compact status marker for a workflow phase."
  @spec phase_marker(non_neg_integer(), Turn.t()) :: String.t()
  def phase_marker(index, turn) do
    case phase_state(index, turn) do
      :completed -> "[x]"
      :current -> "[>]"
      :pending -> "[ ]"
    end
  end

  @doc "Returns the presentation class for a workflow phase's status."
  @spec phase_class(non_neg_integer(), Turn.t()) :: String.t()
  def phase_class(index, turn) do
    case phase_state(index, turn) do
      :completed -> "text-success"
      :current -> "font-bold text-primary"
      :pending -> "text-muted"
    end
  end

  @doc "Returns the gate suffix for phases that require a decision."
  @spec gate_label(map()) :: String.t()
  def gate_label(phase) do
    if Squad.gate?(phase), do: "  [gate]", else: ""
  end

  @doc "Formats an authoritative GateResolution for display."
  @spec resolution_label(GateResolution.t()) :: String.t()
  def resolution_label(resolution) do
    base =
      "#{resolution.phase} / cycle #{resolution.cycle} / #{resolution.decision} / " <>
        Atom.to_string(resolution.authority)

    if resolution.target_phase do
      "#{base} -> #{resolution.target_phase}"
    else
      base
    end
  end

  @doc "Formats a pending owner GateReview for display."
  @spec review_label(GateReview.t()) :: String.t()
  def review_label(review) do
    "#{review.phase} / cycle #{review.cycle} / leader recommends " <>
      review.recommendation.decision
  end

  @doc "Formats a recorded squad artifact for display."
  @spec artifact_label(map()) :: String.t()
  def artifact_label(artifact) do
    "#{artifact.kind} / #{artifact.phase} / cycle #{artifact.cycle}"
  end

  @doc "Formats a squad retry or rework record for display."
  @spec retry_label(map()) :: String.t()
  def retry_label(retry) do
    "#{retry.phase} / #{retry.role_id} / attempt #{retry.attempt} / #{retry.kind}"
  end

  @doc "Aggregates available token and cost usage across a turn's invocations."
  @spec summarize_usage(Turn.t(), Projection.t()) :: usage_summary()
  def summarize_usage(turn, projection) do
    turn.invocation_order
    |> Enum.map(&projection.invocations[&1])
    |> Enum.map(&(&1 && &1.usage))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(
      %{tokens: 0, cost: 0.0, cost_known?: false, invocations: 0},
      &add_usage/2
    )
  end

  @doc "Formats an invocation usage summary while preserving unknown-cost status."
  @spec usage_label(usage_summary()) :: String.t()
  def usage_label(%{invocations: 0}), do: "usage unavailable"

  def usage_label(usage) do
    base = "#{usage.tokens} tokens / #{usage.invocations} measured invocations"

    if usage.cost_known? do
      cost = :erlang.float_to_binary(usage.cost * 1.0, decimals: 4)
      "#{base} / $#{cost}"
    else
      "#{base} / cost unavailable"
    end
  end

  defp phase_state(index, turn) do
    phase_index = turn.squad.phase_index

    cond do
      index < phase_index -> :completed
      index == phase_index and turn.status == :terminal -> :completed
      index == phase_index -> :current
      true -> :pending
    end
  end

  defp add_usage(usage, total) do
    cost = usage_number(usage, :cost)

    %{
      tokens: total.tokens + usage_tokens(usage),
      cost: total.cost + (cost || 0),
      cost_known?: total.cost_known? or not is_nil(cost),
      invocations: total.invocations + 1
    }
  end

  defp usage_tokens(usage) do
    tokens = usage_value(usage, :tokens)

    cond do
      is_number(usage_number(usage, :total_tokens)) -> usage_number(usage, :total_tokens)
      is_number(tokens) -> tokens
      is_map(tokens) -> nested_token_total(tokens)
      true -> split_token_total(usage)
    end
    |> trunc()
  end

  defp nested_token_total(tokens) do
    usage_number(tokens, :total) ||
      (usage_number(tokens, :input) || 0) + (usage_number(tokens, :output) || 0)
  end

  defp split_token_total(usage) do
    prompt = usage_number(usage, :prompt_tokens) || usage_number(usage, :input_tokens) || 0

    completion =
      usage_number(usage, :completion_tokens) || usage_number(usage, :output_tokens) || 0

    prompt + completion
  end

  defp usage_number(usage, key) do
    case usage_value(usage, key) do
      value when is_number(value) -> value
      _value -> nil
    end
  end

  defp usage_value(usage, key) do
    Map.get(usage, key, Map.get(usage, Atom.to_string(key)))
  end
end
