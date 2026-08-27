defmodule ReyCode.Orchestration.ContextCompaction do
  @moduledoc """
  Builds bounded, extractive context summaries at durable Room boundaries.

  The full transcript remains in the event log and Projection. Only provider
  context changes: messages at or before the recorded boundary are replaced by
  the persisted summary. Compaction is deterministic and never performs
  provider work inside the Engine.
  """

  alias ReyCode.Orchestration.{EventEntries, Projection, Room}

  @bytes_per_token 4
  @summary_fraction 4
  @minimum_summary_bytes 1_024
  @maximum_summary_bytes 262_144
  @summary_prefix "Earlier conversation context (extractive summary):\n"

  @doc "Returns one compaction event when estimated context exceeds its token budget."
  @spec entry(Room.t(), Projection.t(), pos_integer()) ::
          :unchanged | {:compact, EventEntries.event_entry()}
  def entry(%Room{} = room, %Projection{} = projection, context_budget_tokens) do
    messages = source_messages(room, projection)
    source_bytes = source_bytes(room.context_summary, messages)
    budget_bytes = context_budget_tokens * @bytes_per_token

    if source_bytes > budget_bytes do
      summary_bytes = summary_bytes(budget_bytes)
      summary = summarize(room.context_summary, messages, summary_bytes)

      metrics = %{
        source_message_count: length(messages),
        source_bytes: source_bytes
      }

      {:compact, EventEntries.context_compacted(room, projection.sequence, summary, metrics)}
    else
      :unchanged
    end
  end

  defp source_messages(room, projection) do
    room.message_order
    |> Enum.map(&projection.messages[&1])
    |> Enum.filter(fn message ->
      message.status == :completed and message.created_sequence > room.context_boundary_sequence
    end)
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
    available_bytes = max(max_bytes - byte_size(@summary_prefix), 0)

    entries =
      messages
      |> Enum.reverse()
      |> Enum.map(&format_message/1)
      |> maybe_append_previous(previous_summary)
      |> take_newest(available_bytes)

    @summary_prefix <> Enum.join(entries, "\n\n")
  end

  defp format_message(message) do
    name = if message.author, do: message.author.name, else: Atom.to_string(message.role)
    name <> ":\n" <> (message.body || "")
  end

  defp maybe_append_previous(entries, nil), do: entries
  defp maybe_append_previous(entries, summary), do: entries ++ ["Previous summary:\n" <> summary]

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

  defp truncate_tail(value, max_bytes) do
    marker = "…"
    content_bytes = max(max_bytes - byte_size(marker), 0)

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

    if max_bytes >= byte_size(marker), do: marker <> tail, else: ""
  end
end
