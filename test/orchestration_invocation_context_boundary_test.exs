defmodule ReyCode.Orchestration.InvocationContextBoundaryTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Context,
    Invocation,
    InvocationContextBoundary,
    InvocationContextReduction,
    InvocationContextSummary,
    InvocationExecution,
    ProviderRound,
    Session,
    ToolRun,
    Turn
  }

  alias ReyCode.Provider.{Request, Response, Runtime, ToolCall}

  defmodule SummaryProvider do
    @behaviour ReyCode.Provider

    @impl true
    def stream(%Runtime{config: config}, request, _emit) do
      send(config.test_pid, {:summary_request, request})
      config.response
    end
  end

  test "builds a bounded boundary over complete old rounds and keeps the newest round" do
    invocation = invocation_with_rounds(3, 8_000)

    assert {:ok, boundary} = InvocationContextReduction.prepare(invocation, 4_096)
    assert boundary.through_round_index == 1
    assert boundary.source_round_count == 2
    assert boundary.summary_bytes <= 4_096
    assert boundary.generator == "extractive-v1"
    assert :ok = InvocationContextReduction.validate(invocation, boundary)

    execution_context = %{invocation.execution_context | context_boundary: boundary}
    compacted = %{invocation | execution_context: execution_context}
    turn = %Turn{id: "turn-1", session_id: "session-1", mode: :direct}

    messages = Context.messages(%Session{}, turn, compacted, %{})

    assert [%{role: :user, content: summary}, %{role: :assistant}, %{role: :tool}] = messages
    assert summary =~ "durable summary of earlier rounds"
    assert List.last(compacted.rounds).text =~ "assistant round 2"
  end

  test "rejects incomplete tool-call rounds and stale source metadata" do
    invocation = invocation_with_rounds(2, 32)
    incomplete = %{invocation | tool_runs: Map.delete(invocation.tool_runs, "run-0")}

    assert {:error, :incomplete_invocation_context_source} =
             InvocationContextReduction.prepare(incomplete)

    assert {:ok, boundary} = InvocationContextReduction.prepare(invocation)
    stale = %{boundary | source_digest: String.duplicate("0", 64)}

    assert {:error, :stale_invocation_context_source} =
             InvocationContextReduction.validate(invocation, stale)
  end

  test "a later boundary chains from the previous durable summary" do
    invocation = invocation_with_rounds(3, 64)
    assert {:ok, first} = InvocationContextReduction.prepare(invocation)

    expanded = invocation_with_rounds(5, 64)
    execution_context = %{expanded.execution_context | context_boundary: first}
    expanded = %{expanded | execution_context: execution_context}

    assert {:ok, second} = InvocationContextReduction.prepare(expanded)
    assert second.through_round_index == 3
    assert second.source_bytes > first.source_bytes
    assert second.source_digest != first.source_digest
    assert second.summary =~ "Previous boundary summary"
    assert :ok = InvocationContextReduction.validate(expanded, second)
  end

  test "boundary wire data round-trips and rejects inconsistent summary bytes" do
    invocation = invocation_with_rounds(2, 64)
    assert {:ok, boundary} = InvocationContextReduction.prepare(invocation)

    assert {:ok, restored} =
             boundary |> InvocationContextBoundary.to_wire() |> InvocationContextBoundary.new()

    assert restored == boundary

    invalid = boundary |> InvocationContextBoundary.to_wire() |> Map.put("summary_bytes", 1)

    assert {:error, :invalid_invocation_context_boundary} =
             InvocationContextBoundary.new(invalid)
  end

  test "semantic refinement is bounded, tool-free, and preserves source identity" do
    invocation = invocation_with_rounds(2, 64)
    assert {:ok, boundary} = InvocationContextReduction.prepare(invocation)

    runtime = %Runtime{
      module: SummaryProvider,
      status: :configured,
      config: %{test_pid: self(), response: {:ok, Response.new(text: "Concise facts")}}
    }

    assert {:ok, refined} = InvocationContextSummary.refine(boundary, runtime, provider_request())
    assert refined.summary == "Concise facts"
    assert refined.generator == "semantic-v1"
    assert refined.source_digest == boundary.source_digest

    assert_receive {:summary_request, summary_request}
    assert summary_request.system_prompt_mode == :frozen
    assert summary_request.tool_names == []
    assert [%{role: :user, content: content}] = summary_request.messages
    assert content == boundary.summary
  end

  test "semantic refinement fails closed on tool calls or oversized output" do
    invocation = invocation_with_rounds(2, 64)
    assert {:ok, boundary} = InvocationContextReduction.prepare(invocation)
    call = ToolCall.new("summary-call", "read", %{"path" => "secret"})

    tool_runtime = %Runtime{
      module: SummaryProvider,
      status: :configured,
      config: %{test_pid: self(), response: {:ok, Response.new(tool_calls: [call])}}
    }

    assert {:error, %{category: :invalid_output}} =
             InvocationContextSummary.refine(boundary, tool_runtime, provider_request())

    oversized_runtime = %{
      tool_runtime
      | config: %{
          test_pid: self(),
          response:
            {:ok,
             Response.new(
               text: String.duplicate("x", InvocationContextBoundary.maximum_summary_bytes() + 1)
             )}
        }
    }

    assert {:error, %{category: :invalid_output}} =
             InvocationContextSummary.refine(boundary, oversized_runtime, provider_request())
  end

  defp invocation_with_rounds(round_count, output_bytes) do
    {rounds, runs, order} =
      Enum.reduce(0..(round_count - 1), {[], %{}, []}, fn index, {rounds, runs, order} ->
        call = ToolCall.new("call-#{index}", "read", %{"path" => "file-#{index}.txt"})
        run_id = "run-#{index}"

        round = %ProviderRound{
          index: index,
          text: "assistant round #{index}",
          tool_calls: [call]
        }

        run = %ToolRun{
          id: run_id,
          tool_call_id: call.id,
          round_index: index,
          tool: call.tool,
          arguments: call.arguments,
          status: :completed,
          result: %{
            "output" => String.duplicate(Integer.to_string(index), output_bytes),
            "truncated" => false,
            "metadata" => %{}
          }
        }

        {rounds ++ [round], Map.put(runs, run_id, run), order ++ [run_id]}
      end)

    %Invocation{
      id: "inv-1",
      session_id: "session-1",
      turn_id: "turn-1",
      message_id: "message-1",
      status: :running,
      execution_context: %InvocationExecution{},
      rounds: rounds,
      tool_runs: runs,
      tool_run_order: order
    }
  end

  defp provider_request do
    %Request{
      invocation_id: "inv-1",
      turn_id: "turn-1",
      session_id: "session-1",
      mode: :direct,
      participant: %{
        id: "assistant",
        name: "Assistant",
        perspective: "implementation",
        provider: :simulator,
        model: "test"
      },
      system_prompt: "Original prompt",
      messages: [],
      workspace: System.tmp_dir!(),
      resume_from: 9,
      round_index: 2
    }
  end
end
