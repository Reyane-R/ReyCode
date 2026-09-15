defmodule ReyCode.Orchestration.Challenge do
  @moduledoc "Targeted, tool-free review of one recorded answer or decision using a frozen evidence packet."

  alias ReyCode.Memory.Store
  alias ReyCode.Orchestration.{Message, StrategicReview, Turn}

  @memory_kinds ~w(decision assumption)
  @max_memory_count 100

  @doc "The same kind-filtered memory window is used by target selection and Engine capture."
  def memories(workspace, server \\ Store) do
    Store.list(workspace, @memory_kinds, @max_memory_count, server)
  catch
    :exit, _reason -> {:error, :challenge_memory_unavailable}
  end

  @questions [
    {"support", "What evidence supports this claim?"},
    {"contradict", "What evidence contradicts this claim?"},
    {"assumptions", "Which assumptions remain untested?"},
    {"alternative", "What simpler alternative meets the same requirement?"},
    {"experiment", "What bounded check would distinguish the alternatives?"}
  ]

  @doc "The bounded questions available in the challenge picker."
  def questions, do: @questions

  @doc "Captures the selected source only; missing, foreign and unfinished targets are rejected."
  def capture(projection, session, entries, %{"kind" => kind, "id" => id, "question" => question})
      when is_binary(id) and byte_size(id) in 1..256 do
    case List.keyfind(@questions, question, 0) do
      nil -> {:error, :invalid_challenge_question}
      {_key, text} -> capture_target(projection, session, entries, kind, id, text)
    end
  end

  def capture(_projection, _session, _entries, _selection),
    do: {:error, :invalid_challenge_target}

  defp capture_target(projection, session, _entries, "answer", id, question) do
    with %Message{role: :assistant, session_id: session_id} = message <- projection.messages[id],
         true <- session_id == session.id,
         %Turn{status: :terminal, strategy_review: nil} = turn <-
           projection.turns[message.turn_id],
         true <- turn.session_id == session.id and message.invocation_id in turn.invocation_order,
         %{message_id: ^id} <- projection.invocations[message.invocation_id] do
      StrategicReview.capture_answer(projection, session, message, focus("answer", id, question))
    else
      _ -> {:error, :invalid_challenge_target}
    end
  end

  defp capture_target(projection, session, entries, "decision", id, question) do
    entry =
      Enum.find(
        Enum.take(entries, 100),
        &(&1.id == id and &1.project == session.workspace and &1.kind in ~w(decision assumption))
      )

    if entry do
      StrategicReview.capture(
        %{projection | turns: %{}},
        session,
        [entry],
        focus("decision", id, question)
      )
    else
      {:error, :challenge_evidence_unavailable}
    end
  end

  defp capture_target(_projection, _session, _entries, _kind, _id, _question),
    do: {:error, :invalid_challenge_target}

  defp focus(kind, id, question) do
    "Challenge #{kind} #{id}. #{question}\n" <>
      "Selection is restricted to this target, not a workspace-wide audit. " <>
      "Separate recorded actions/results from model-authored claims and explanations. " <>
      "Reasoning text is not proof of causation. State missing or clipped evidence explicitly. " <>
      "A decision's free-text evidence is a claim, not a verified citation. " <>
      "Use the experiment field for a proposed follow-up, never claim it was executed."
  end

  @doc "Enumerates navigable packet-local sources, retaining their exact frozen previews and durable IDs."
  def sources(%StrategicReview{} = packet) do
    Enum.flat_map(packet.turns, fn turn ->
      [
        turn
        | Enum.flat_map(turn["outputs"], fn invocation -> [invocation | invocation["tools"]] end)
      ]
    end) ++ packet.memory
  end

  @doc "Resolves a citation only against the frozen packet; never reads current files or artifacts."
  def source(packet, source_id) do
    case Enum.find(sources(packet), &(&1["source_id"] == source_id)) do
      nil -> {:error, :evidence_not_in_packet}
      source -> {:ok, source}
    end
  end

  @doc "Returns experiments only from a citation-validated report."
  def experiments(packet, text) do
    with {:ok, _text} <- StrategicReview.validate_output(packet, text),
         {:ok, report} <- Jason.decode(text) do
      {:ok, Enum.map(report["findings"], & &1["experiment"])}
    end
  end
end
