defmodule ReyCode.Orchestration.InvocationContextReduction do
  @moduledoc "Builds bounded context boundaries from completed Invocation round prefixes."

  alias ReyCode.Hashing

  alias ReyCode.Orchestration.{
    Invocation,
    InvocationContextBoundary,
    ToolRuns
  }

  alias ReyCode.Provider.TextBuffer

  @maximum_rounds_per_pass 64
  @maximum_entry_bytes 2_048
  @summary_prefix "Earlier Invocation context (extractive summary):\n"

  @doc "Builds the next bounded extractive boundary while retaining the newest round verbatim."
  @spec prepare(Invocation.t(), pos_integer()) ::
          :unchanged | {:ok, InvocationContextBoundary.t()} | {:error, atom()}
  def prepare(
        %Invocation{} = invocation,
        max_summary_bytes \\ InvocationContextBoundary.maximum_summary_bytes()
      ) do
    current = invocation.execution_context.context_boundary
    start_index = next_round_index(current)
    final_index = length(invocation.rounds) - 2

    cond do
      final_index < start_index ->
        :unchanged

      max_summary_bytes <= byte_size(@summary_prefix) ->
        {:error, :context_summary_budget_too_small}

      true ->
        through_round_index = min(final_index, start_index + @maximum_rounds_per_pass - 1)

        case source(invocation, start_index, through_round_index) do
          {:ok, source} ->
            summary = summary(current, source.entries, max_summary_bytes)

            InvocationContextBoundary.new(%{
              through_round_index: through_round_index,
              summary: summary,
              source_digest: source_digest(current, source.canonical),
              source_round_count: through_round_index + 1,
              source_bytes: previous_source_bytes(current) + source.bytes,
              summary_bytes: byte_size(summary),
              generator: "extractive-v1"
            })

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Validates that a proposed boundary covers the current durable round source."
  @spec validate(Invocation.t(), InvocationContextBoundary.t()) :: :ok | {:error, atom()}
  def validate(%Invocation{} = invocation, %InvocationContextBoundary{} = boundary) do
    current = invocation.execution_context.context_boundary
    start_index = next_round_index(current)

    with true <- boundary.through_round_index >= start_index,
         true <- boundary.through_round_index < length(invocation.rounds) - 1,
         {:ok, source} <- source(invocation, start_index, boundary.through_round_index),
         true <-
           boundary.source_digest == source_digest(current, source.canonical),
         true <- boundary.source_round_count == boundary.through_round_index + 1,
         true <-
           boundary.source_bytes == previous_source_bytes(current) + source.bytes do
      :ok
    else
      false -> {:error, :stale_invocation_context_source}
      {:error, reason} -> {:error, reason}
    end
  end

  defp source(invocation, start_index, through_round_index) do
    rounds = Enum.slice(invocation.rounds, start_index..through_round_index)

    with true <- length(rounds) == through_round_index - start_index + 1,
         true <- Enum.all?(rounds, &complete_round?(invocation, &1)) do
      entries = Enum.map(rounds, &entry(invocation, &1))
      canonical = canonical(entries)
      {:ok, %{entries: entries, canonical: canonical, bytes: byte_size(canonical)}}
    else
      false -> {:error, :incomplete_invocation_context_source}
    end
  end

  defp complete_round?(invocation, round) do
    Enum.all?(round.tool_calls || [], fn call ->
      case ToolRuns.run_for_call(invocation, call.id) do
        nil -> false
        run -> ToolRuns.terminal?(run.status)
      end
    end)
  end

  defp entry(invocation, round) do
    %{
      "round_index" => round.index,
      "assistant" => round.text || "",
      "steering" => Enum.map(round.steering || [], & &1.body),
      "tools" =>
        Enum.map(round.tool_calls || [], fn call ->
          run = ToolRuns.run_for_call(invocation, call.id)

          %{
            "call_id" => call.id,
            "tool" => call.tool,
            "arguments" => call.arguments,
            "result" => ToolRuns.result_content(run)
          }
        end)
    }
  end

  defp summary(previous, entries, max_summary_bytes) do
    available_bytes = max_summary_bytes - byte_size(@summary_prefix)
    previous_text = previous_summary(previous, div(available_bytes, 2))
    available_bytes = available_bytes - byte_size(previous_text)

    {selected, omitted_count} = select_newest_entries(entries, available_bytes)

    omission =
      if omitted_count > 0,
        do: "\n#{omitted_count} earlier newly covered round(s) omitted from extractive detail.",
        else: ""

    body = previous_text <> Enum.join(selected, "\n\n") <> omission
    @summary_prefix <> TextBuffer.truncate_utf8(body, available_bytes + byte_size(previous_text))
  end

  defp previous_summary(nil, _max_bytes), do: ""

  defp previous_summary(boundary, max_bytes) do
    text = "Previous boundary summary:\n" <> boundary.summary <> "\n\n"
    TextBuffer.truncate_utf8(text, max_bytes)
  end

  defp select_newest_entries(entries, available_bytes) do
    entries
    |> Enum.reverse()
    |> Enum.map(&format_entry/1)
    |> Enum.reduce_while({[], available_bytes, 0}, fn entry, {selected, remaining, omitted} ->
      required = byte_size(entry) + if(selected == [], do: 0, else: 2)

      if required <= remaining,
        do: {:cont, {[entry | selected], remaining - required, omitted}},
        else: {:cont, {selected, remaining, omitted + 1}}
    end)
    |> then(fn {selected, _remaining, omitted} -> {selected, omitted} end)
  end

  defp format_entry(entry) do
    tools =
      Enum.map_join(entry["tools"], "\n", fn tool ->
        arguments = tool["arguments"] |> Jason.encode!() |> clip(div(@maximum_entry_bytes, 4))
        result = clip(tool["result"], div(@maximum_entry_bytes, 2))
        "Tool #{tool["tool"]} #{arguments}\nResult #{result}"
      end)

    [
      "Round #{entry["round_index"]}",
      clip(entry["assistant"], div(@maximum_entry_bytes, 2)),
      tools
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> clip(@maximum_entry_bytes)
  end

  defp clip(value, max_bytes) when is_binary(value) do
    clipped = TextBuffer.truncate_utf8(value, max_bytes)

    if byte_size(clipped) < byte_size(value),
      do: clipped <> " [context excerpt clipped]",
      else: clipped
  end

  defp canonical(value), do: value |> canonical_term() |> :erlang.term_to_binary()

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonical_term(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp source_digest(nil, canonical), do: Hashing.sha256_hex(canonical)

  defp source_digest(boundary, canonical),
    do: Hashing.sha256_hex(boundary.source_digest <> canonical)

  defp next_round_index(nil), do: 0
  defp next_round_index(boundary), do: boundary.through_round_index + 1
  defp previous_source_bytes(nil), do: 0
  defp previous_source_bytes(boundary), do: boundary.source_bytes
end
