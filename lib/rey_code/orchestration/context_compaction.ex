defmodule ReyCode.Orchestration.ContextCompaction do
  @moduledoc """
  Builds bounded, extractive context summaries at durable Session boundaries.

  The full transcript remains in the event log and Projection. Only provider
  context changes: messages at or before the recorded boundary are replaced by
  the persisted summary. Compaction is deterministic and never performs
  provider work inside the Engine.
  """

  alias ReyCode.Orchestration.{EventEntries, Projection, Session, Turn}

  @bytes_per_token 4
  @summary_fraction 4
  @minimum_summary_bytes 1_024
  @maximum_summary_bytes 262_144
  @summary_prefix "Earlier conversation context (extractive summary):\n"
  @truncation_marker "…"

  @doc "Maximum durable Session summary size."
  @spec maximum_summary_bytes() :: pos_integer()
  def maximum_summary_bytes, do: @maximum_summary_bytes

  @doc "Returns one compaction event when estimated context exceeds its token budget."
  @spec entry(Session.t(), Turn.t(), Projection.t(), pos_integer()) ::
          :unchanged | {:compact, EventEntries.event_entry()}
  def entry(
        %Session{} = session,
        %Turn{} = turn,
        %Projection{} = projection,
        context_budget_tokens
      ) do
    through_sequence =
      safe_through_sequence(session, projection, turn.context_through_sequence - 1)

    messages = source_messages(session, projection, through_sequence)
    source_bytes = source_bytes(session.context_summary, messages)
    budget_bytes = context_budget_tokens * @bytes_per_token
    summary_bytes = summary_bytes(budget_bytes)

    if through_sequence > session.context_boundary_sequence and messages != [] and
         summary_can_advance?(session.context_summary, messages, summary_bytes) and
         source_bytes > budget_bytes do
      summary = summarize(session.context_summary, messages, summary_bytes)

      metrics = %{
        source_message_count: length(messages),
        source_bytes: source_bytes
      }

      {:compact, EventEntries.context_compacted(session, through_sequence, summary, metrics)}
    else
      :unchanged
    end
  end

  @doc "Builds a smaller boundary using an exact provider-preflight summary allowance."
  @spec prepare(Session.t(), Turn.t(), Projection.t(), pos_integer()) ::
          :unchanged | {:compact, EventEntries.event_entry()}
  def prepare(%Session{} = session, %Turn{} = turn, %Projection{} = projection, max_summary_bytes)
      when is_integer(max_summary_bytes) and max_summary_bytes > 0 do
    through_sequence =
      safe_through_sequence(session, projection, turn.context_through_sequence - 1)

    messages = source_messages(session, projection, through_sequence)

    cond do
      through_sequence <= session.context_boundary_sequence or messages == [] ->
        recompact_summary(session, max_summary_bytes)

      not summary_can_advance?(session.context_summary, messages, max_summary_bytes) ->
        recompact_summary(session, max_summary_bytes)

      true ->
        compact_messages(session, messages, through_sequence, max_summary_bytes)
    end
  end

  defp compact_messages(session, messages, through_sequence, max_summary_bytes) do
    source_bytes = source_bytes(session.context_summary, messages)
    summary_bytes = min(max_summary_bytes, @maximum_summary_bytes)
    summary = summarize(session.context_summary, messages, summary_bytes)

    if byte_size(summary) < source_bytes do
      metrics = %{source_message_count: length(messages), source_bytes: source_bytes}
      {:compact, EventEntries.context_compacted(session, through_sequence, summary, metrics)}
    else
      :unchanged
    end
  end

  defp recompact_summary(%Session{context_summary: nil}, _max_summary_bytes), do: :unchanged

  defp recompact_summary(%Session{} = session, max_summary_bytes) do
    source_bytes = byte_size(session.context_summary)
    minimum_summary_bytes = minimum_retained_bytes(session.context_summary)

    summary_bytes =
      max_summary_bytes
      |> max(minimum_summary_bytes)
      |> min(@maximum_summary_bytes)

    if source_bytes > summary_bytes and summary_bytes >= minimum_summary_bytes do
      summary = truncate_tail(session.context_summary, summary_bytes)
      metrics = %{source_message_count: 0, source_bytes: source_bytes}

      {:compact,
       EventEntries.context_compacted(
         session,
         session.context_boundary_sequence,
         summary,
         metrics
       )}
    else
      :unchanged
    end
  end

  defp source_messages(session, projection, through_sequence) do
    session.message_order
    |> Enum.map(&projection.messages[&1])
    |> Enum.filter(fn message ->
      message.status == :completed and
        message.created_sequence > session.context_boundary_sequence and
        message.created_sequence <= through_sequence
    end)
  end

  defp safe_through_sequence(session, projection, requested_through_sequence) do
    requested_through_sequence =
      min(requested_through_sequence, before_nonterminal_turns(session, projection))

    first_incomplete_sequence =
      session.message_order
      |> Enum.map(&projection.messages[&1])
      |> Enum.filter(
        &(&1.created_sequence > session.context_boundary_sequence and
            &1.created_sequence <= requested_through_sequence and
            message_blocks_boundary?(&1, projection))
      )
      |> Enum.map(& &1.created_sequence)
      |> Enum.min(fn -> requested_through_sequence + 1 end)

    max(min(requested_through_sequence, first_incomplete_sequence - 1), 0)
  end

  defp before_nonterminal_turns(session, projection) do
    session.message_order
    |> Enum.map(&projection.messages[&1])
    |> Enum.filter(&current_input?(&1, projection))
    |> Enum.map(&(&1.created_sequence - 1))
    |> Enum.min(fn -> projection.sequence end)
  end

  defp current_input?(%{invocation_id: nil} = message, projection) do
    case Map.get(projection.turns, message.turn_id) do
      %{status: status} when status in [:queued, :running] -> true
      _terminal_or_missing -> false
    end
  end

  defp current_input?(_message, _projection), do: false

  defp message_blocks_boundary?(%{status: :completed}, _projection), do: false

  defp message_blocks_boundary?(message, projection) do
    case Map.get(projection.turns, message.turn_id) do
      %{status: status} when status in [:queued, :running] -> true
      nil -> true
      _terminal -> false
    end
  end

  defp source_bytes(summary, messages) do
    summary_bytes = if is_binary(summary), do: byte_size(summary), else: 0
    summary_bytes + Enum.reduce(messages, 0, &(&2 + byte_size(&1.body || "")))
  end

  defp summary_bytes(budget_bytes) do
    budget_bytes
    |> div(@summary_fraction)
    |> max(min(@minimum_summary_bytes, budget_bytes))
    |> min(@maximum_summary_bytes)
    |> min(budget_bytes)
  end

  defp summarize(previous_summary, messages, max_bytes) do
    if max_bytes <= byte_size(@summary_prefix) do
      messages
      |> List.first()
      |> format_message()
      |> truncate_tail(max_bytes)
    else
      summarize_with_prefix(previous_summary, messages, max_bytes)
    end
  end

  defp summarize_with_prefix(previous_summary, messages, max_bytes) do
    available_bytes = max_bytes - byte_size(@summary_prefix)

    entries = summary_entries(previous_summary, messages, available_bytes)

    @summary_prefix <> Enum.join(entries, "\n\n")
  end

  defp summary_entries(nil, messages, available_bytes) do
    messages
    |> Enum.map(&format_message/1)
    |> take_newest(available_bytes)
  end

  defp summary_entries(previous_summary, messages, available_bytes) do
    previous_entry = "Previous summary:\n" <> previous_summary
    minimum_previous_bytes = minimum_retained_bytes(previous_entry)

    minimum_message_bytes =
      messages |> List.first() |> format_message() |> minimum_retained_bytes()

    distributable_bytes = available_bytes - 2
    maximum_previous_bytes = distributable_bytes - minimum_message_bytes

    previous_bytes =
      min(
        byte_size(previous_entry),
        min(max(div(distributable_bytes, 2), minimum_previous_bytes), maximum_previous_bytes)
      )

    message_bytes = distributable_bytes - previous_bytes

    current_entries = messages |> Enum.map(&format_message/1) |> take_newest(message_bytes)
    previous_entry = truncate_tail(previous_entry, previous_bytes)

    [previous_entry | current_entries]
    |> Enum.reject(&(&1 == ""))
  end

  defp format_message(message) do
    name = if message.author, do: message.author.name, else: Atom.to_string(message.role)
    name <> ":\n" <> (message.body || "")
  end

  defp take_newest(entries, max_bytes) do
    entries
    |> Enum.reduce_while({[], max_bytes}, fn entry, {selected, remaining} ->
      separator_bytes = if selected == [], do: 0, else: 2
      required_bytes = byte_size(entry) + separator_bytes

      cond do
        required_bytes <= remaining ->
          {:cont, {[entry | selected], remaining - required_bytes}}

        selected == [] and remaining > 0 ->
          {:halt, {[truncate_tail(entry, remaining)], 0}}

        true ->
          {:halt, {selected, remaining}}
      end
    end)
    |> elem(0)
  end

  defp summary_can_advance?(previous_summary, messages, max_bytes)
       when previous_summary in [nil, ""] do
    message_bytes = messages |> List.first() |> format_message() |> minimum_retained_bytes()
    prefix_bytes = byte_size(@summary_prefix)
    available_bytes = if max_bytes <= prefix_bytes, do: max_bytes, else: max_bytes - prefix_bytes
    available_bytes >= message_bytes
  end

  defp summary_can_advance?(previous_summary, messages, max_bytes) do
    previous_bytes = minimum_retained_bytes("Previous summary:\n" <> previous_summary)
    message_bytes = messages |> List.first() |> format_message() |> minimum_retained_bytes()
    max_bytes >= byte_size(@summary_prefix) + previous_bytes + message_bytes + 2
  end

  defp minimum_retained_bytes(value) do
    last_grapheme = value |> String.graphemes() |> List.last()
    byte_size(@truncation_marker) + byte_size(last_grapheme)
  end

  defp truncate_tail(value, max_bytes) do
    content_bytes = max(max_bytes - byte_size(@truncation_marker), 0)

    tail =
      value
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn grapheme, {kept, bytes} ->
        next_bytes = bytes + byte_size(grapheme)

        if next_bytes <= content_bytes,
          do: {:cont, {[grapheme | kept], next_bytes}},
          else: {:halt, {kept, bytes}}
      end)
      |> elem(0)
      |> IO.iodata_to_binary()

    if max_bytes >= byte_size(@truncation_marker), do: @truncation_marker <> tail, else: ""
  end
end
