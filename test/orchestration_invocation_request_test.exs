defmodule ReyCode.Orchestration.InvocationRequestTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.InvocationRequest
  alias ReyCode.Provider.Request

  test "builds the complete provider request from durable projection state" do
    participant = %{
      id: "builder",
      name: "Builder",
      perspective: "implementation",
      provider: :simulator,
      model: nil
    }

    invocation = %{
      id: "inv-1",
      turn_id: "turn-1",
      room_id: "room-1",
      participant: participant,
      system_prompt: "Build the smallest change",
      last_frame_sequence: 3,
      attempt: 2,
      label: "revision",
      phase: "implementation",
      cycle: 1,
      logical_work_id: "work-1",
      dependencies: ["inv-0"]
    }

    projection = %{
      rooms: %{
        "room-1" => %{
          id: "room-1",
          workspace: "/workspace",
          message_order: ["msg-user"]
        }
      },
      turns: %{
        "turn-1" => %{
          id: "turn-1",
          mode: :compare,
          context_through_sequence: 4
        }
      },
      messages: %{
        "msg-user" => %{
          role: :user,
          body: "Please revise it",
          author: %{name: "You"},
          status: :completed,
          created_sequence: 4
        }
      }
    }

    assert InvocationRequest.build(invocation, projection, 25) == %Request{
             invocation_id: "inv-1",
             turn_id: "turn-1",
             room_id: "room-1",
             mode: :compare,
             participant: participant,
             system_prompt: "Build the smallest change",
             messages: [
               %{role: :user, content: "Please revise it", author: %{name: "You"}}
             ],
             workspace: "/workspace",
             resume_from: 3,
             attempt: 2,
             label: "revision",
             phase: "implementation",
             cycle: 1,
             logical_work_id: "work-1",
             agent_delay_ms: 25,
             dependencies: ["inv-0"]
           }
  end
end
