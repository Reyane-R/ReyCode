defmodule ReyCode.Orchestration.Delegation do
  @moduledoc """
  Pure policy for agent-initiated delegation over the `spawn_task` orchestration
  tool.

  The high-tier caller decides *when* to delegate; this module decides *whether
  a call is admissible*: strict argument shape, exact-name addressing against
  task-kind participants only, persisted depth bound, and explicit per-caller
  caps. Every rejection reason is deterministic and recorded as a failed tool
  run — uncertainty never spawns a child invocation.
  """

  alias ReyCode.Orchestration.{Invocation, Participant, Projection}

  @tool_name "spawn_task"

  @max_children_per_invocation 8
  @brief_max_bytes 16_384
  @report_max_bytes 16_384

  @type bounds :: %{max_children: pos_integer(), brief_max_bytes: pos_integer()}

  @type rejection ::
          :invalid_arguments
          | :brief_too_large
          | :delegation_depth_exceeded
          | :child_cap_exceeded
          | :unknown_agent
          | :primary_target

  @doc "The orchestration tool name agents call to delegate."
  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @doc "Built-in delegation bounds; configuration may only lower or raise them explicitly."
  @spec default_bounds() :: bounds()
  def default_bounds,
    do: %{max_children: @max_children_per_invocation, brief_max_bytes: @brief_max_bytes}

  @doc """
  Validates one `spawn_task` call against addressing rules and bounds.

  Arguments must be `%{"agent" => binary, "brief" => binary}`; the agent name
  matches exactly one room participant of kind `:task`. Primary participants
  and unknown names reject without spawning.
  """
  @spec authorize(Invocation.t(), term(), Projection.t(), bounds()) ::
          {:ok, Participant.t()} | {:error, rejection()}
  def authorize(invocation, arguments, projection, bounds) do
    with {:ok, agent, brief} <- parse_arguments(arguments),
         :ok <- check_brief(brief, bounds.brief_max_bytes),
         :ok <- check_depth(invocation),
         :ok <- check_child_cap(invocation, bounds.max_children) do
      resolve_participant(projection.rooms[invocation.room_id], agent)
    end
  end

  @doc "Builds the child task-agent system prompt carrying the delegated brief."
  @spec child_system_prompt(Participant.t(), String.t()) :: String.t()
  def child_system_prompt(participant, brief) do
    "You are the #{participant.name} task agent. " <>
      "Standing responsibility: #{participant.perspective}. " <>
      "Complete only the delegated task and report the result.\n\n" <>
      "Delegated task:\n#{brief}"
  end

  @doc """
  Builds the structured tool-run report delivered to the parent conversation.

  The map follows the durable tool-result envelope (`output`/`error`,
  `truncated`, `metadata`) so the recorded round re-encodes it verbatim; the
  child's usage rides in `metadata`.
  """
  @spec report(boolean(), String.t() | nil, map() | nil) :: map()
  def report(ok?, output, usage) do
    text = bounded(output)

    if ok? do
      %{
        "output" => text || "",
        "truncated" => truncated?(text),
        "metadata" => %{"usage" => usage || %{}}
      }
    else
      %{
        "error" => text || "delegation failed",
        "truncated" => false,
        "metadata" => %{"usage" => usage || %{}}
      }
    end
  end

  defp truncated?(text) when is_binary(text), do: byte_size(text) >= @report_max_bytes
  defp truncated?(_), do: false

  defp parse_arguments(%{"agent" => agent, "brief" => brief})
       when is_binary(agent) and is_binary(brief),
       do: {:ok, agent, brief}

  defp parse_arguments(_arguments), do: {:error, :invalid_arguments}

  defp check_brief(brief, brief_max_bytes) do
    if byte_size(brief) > brief_max_bytes,
      do: {:error, :brief_too_large},
      else: :ok
  end

  # Depth is persisted per invocation, so a child calling spawn_task is denied
  # deterministically across restarts, not per process.
  defp check_depth(invocation) do
    if invocation.delegation_depth >= 1,
      do: {:error, :delegation_depth_exceeded},
      else: :ok
  end

  defp check_child_cap(invocation, max_children) do
    children =
      invocation.tool_run_order
      |> List.wrap()
      |> Enum.count(fn run_id ->
        case Map.get(invocation.tool_runs, run_id) do
          %{tool: tool} -> tool == @tool_name
          _other -> false
        end
      end)

    if children >= max_children,
      do: {:error, :child_cap_exceeded},
      else: :ok
  end

  defp resolve_participant(nil, _agent), do: {:error, :unknown_agent}

  defp resolve_participant(room, agent) do
    case Enum.find(room.participants, &(&1.name == agent)) do
      nil -> {:error, :unknown_agent}
      %Participant{kind: :task} = participant -> {:ok, participant}
      %Participant{} -> {:error, :primary_target}
      _seat_or_other -> {:error, :unknown_agent}
    end
  end

  defp bounded(nil), do: nil

  defp bounded(text) when is_binary(text),
    do: binary_slice(text, 0, min(byte_size(text), @report_max_bytes))

  defp bounded(other), do: other
end
