defmodule ReyCode.Orchestration.InvocationContextSummary do
  @moduledoc "Refines a bounded extractive Invocation context boundary without tool authority."

  alias ReyCode.Failure
  alias ReyCode.Orchestration.InvocationContextBoundary
  alias ReyCode.Provider.{Message, Request, Response, Runtime}

  @system_prompt """
  Rewrite the supplied execution-history extract into a concise factual continuation summary.
  Preserve the objective, constraints, findings, file changes, tests, errors, and next action.
  Do not add facts, instructions, tool calls, or recommendations not present in the extract.
  Return only the summary text.
  """

  @doc "Runs one bounded, tool-free provider round to refine an extractive boundary."
  @spec refine(InvocationContextBoundary.t(), Runtime.t(), Request.t()) ::
          {:ok, InvocationContextBoundary.t()} | {:error, Failure.t()}
  def refine(
        %InvocationContextBoundary{} = boundary,
        %Runtime{} = runtime,
        %Request{} = request
      ) do
    summary_request = %{
      request
      | system_prompt_mode: :frozen,
        system_prompt: @system_prompt,
        messages: [Message.new(role: :user, content: boundary.summary)],
        tool_names: [],
        resume_from: 0,
        round_index: 0,
        steering: []
    }

    case stream(runtime, summary_request) do
      {:ok, %Response{tool_calls: [], text: text}} ->
        semantic_boundary(boundary, text)

      {:ok, %Response{}} ->
        {:error, Failure.new(:invalid_output, "Context summary requested tools")}

      {:error, %Failure{} = failure} ->
        {:error, failure}
    end
  end

  defp stream(runtime, request) do
    runtime.module.stream(runtime, request, fn _frame -> :ok end)
  rescue
    error -> {:error, Failure.new(:internal, Exception.message(error))}
  catch
    kind, reason -> {:error, Failure.new(:internal, Exception.format_banner(kind, reason))}
  end

  defp semantic_boundary(boundary, text) when is_binary(text) do
    text = String.trim(text)

    if text != "" and byte_size(text) <= InvocationContextBoundary.maximum_summary_bytes() do
      InvocationContextBoundary.new(%{
        through_round_index: boundary.through_round_index,
        summary: text,
        source_digest: boundary.source_digest,
        source_round_count: boundary.source_round_count,
        source_bytes: boundary.source_bytes,
        summary_bytes: byte_size(text),
        generator: "semantic-v1"
      })
      |> case do
        {:ok, refined} -> {:ok, refined}
        {:error, :invalid_invocation_context_boundary} -> invalid_summary()
      end
    else
      invalid_summary()
    end
  end

  defp semantic_boundary(_boundary, _text), do: invalid_summary()

  defp invalid_summary,
    do: {:error, Failure.new(:invalid_output, "Context summary was empty or too large")}
end
