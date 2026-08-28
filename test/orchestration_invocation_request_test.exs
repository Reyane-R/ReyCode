defmodule ReyCode.Orchestration.InvocationRequestTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.{
    Invocation,
    InvocationRequest,
    Participant,
    Projection,
    Room,
    ToolRun,
    Turn
  }

  alias ReyCode.Orchestration.Message, as: ProjectionMessage
  alias ReyCode.ProjectInstructions.Capture
  alias ReyCode.Provider.{Message, Request, ToolCall}

  test "builds the complete provider request from durable projection state" do
    participant = %Participant{
      id: "builder",
      name: "Builder",
      perspective: "implementation",
      provider: :simulator,
      model: nil
    }

    invocation = %Invocation{
      id: "inv-1",
      turn_id: "turn-1",
      room_id: "room-1",
      participant: participant,
      system_prompt: "Build the smallest change",
      project_instructions: %Capture{
        content: "Project rules from AGENTS.md",
        digest: ReyCode.Hashing.sha256_hex("Project rules from AGENTS.md"),
        sources: ["/workspace/AGENTS.md"]
      },
      last_frame_sequence: 3,
      attempt: 2,
      label: "revision",
      phase: "implementation",
      cycle: 1,
      logical_work_id: "work-1",
      dependencies: ["inv-0"],
      rounds: [
        %{
          index: 0,
          text: "Reading first.",
          tool_calls: [
            %{"id" => "call-1", "tool" => "read", "arguments" => %{"path" => "hello.txt"}}
          ],
          usage: nil
        }
      ],
      tool_runs: %{
        "toolrun-1" => %ToolRun{
          id: "toolrun-1",
          tool_call_id: "call-1",
          round_index: 0,
          tool: "read",
          arguments: %{"path" => "hello.txt"},
          status: :completed,
          result: %{"ok" => true, "output" => "contents", "error" => nil},
          error: nil
        }
      },
      tool_run_order: ["toolrun-1"]
    }

    projection = %Projection{
      rooms: %{
        "room-1" => %Room{
          id: "room-1",
          workspace: "/workspace",
          message_order: ["msg-user"]
        }
      },
      turns: %{
        "turn-1" => %Turn{
          id: "turn-1",
          mode: :compare,
          context_through_sequence: 4
        }
      },
      messages: %{
        "msg-user" => %ProjectionMessage{
          role: :user,
          body: "Please revise it",
          author: %{name: "You"},
          status: :completed,
          created_sequence: 4
        }
      }
    }

    assert InvocationRequest.build(invocation, projection, %{
             agent_delay_ms: 25,
             simulator_opts: [seed: 7]
           }) == %Request{
             invocation_id: "inv-1",
             turn_id: "turn-1",
             room_id: "room-1",
             mode: :compare,
             participant: participant,
             system_prompt:
               "Build the smallest change\n\n" <>
                 "Follow these frozen project instructions for this Invocation:\n\n" <>
                 "Project rules from AGENTS.md",
             messages: [
               Message.new(role: :user, content: "Please revise it", author: %{name: "You"}),
               Message.new(
                 role: :assistant,
                 content: "Reading first.",
                 tool_calls: [
                   ToolCall.new("call-1", "read", %{"path" => "hello.txt"})
                 ]
               ),
               Message.new(
                 role: :tool,
                 content:
                   Jason.encode!(%{
                     "ok" => true,
                     "output" => "contents",
                     "error" => nil,
                     "truncated" => false,
                     "metadata" => %{}
                   }),
                 tool_call_id: "call-1",
                 name: "read"
               )
             ],
             workspace: "/workspace",
             resume_from: 3,
             round_index: 1,
             attempt: 2,
             label: "revision",
             phase: "implementation",
             cycle: 1,
             logical_work_id: "work-1",
             model_tier: :default,
             token_budget_tokens: 100_000,
             used_tokens: nil,
             agent_delay_ms: 25,
             simulator_opts: [seed: 7],
             dependencies: ["inv-0"]
           }
  end
end
