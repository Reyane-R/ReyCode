defmodule ReyCode.Orchestration.SteeringTest do
  use ExUnit.Case, async: true

  alias ReyCode.Event
  alias ReyCode.Orchestration.{Context, Projector, Steering}

  test "steering is pending until the exact provider round consumes it" do
    projection = Projector.replay(base_events())
    invocation = projection.invocations["inv-1"]

    assert Enum.map(invocation.pending_steering, & &1.body) == ["Use the smaller approach"]

    pending_context =
      Context.messages(
        projection.rooms["room-1"],
        projection.turns["turn-1"],
        invocation,
        projection
      )

    assert List.last(pending_context).content =~ "Use the smaller approach"

    steering = Enum.map(invocation.pending_steering, &Steering.to_wire/1)

    round =
      event(6, :provider_round_recorded, %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "round_index" => 0,
        "text" => "Revised answer",
        "tool_calls" => [],
        "usage" => nil,
        "steering" => steering
      })

    projection = Projector.apply(round, projection)
    invocation = projection.invocations["inv-1"]

    assert invocation.pending_steering == []

    assert hd(invocation.rounds).steering |> hd() |> Map.fetch!(:body) ==
             "Use the smaller approach"

    context =
      Context.messages(
        projection.rooms["room-1"],
        projection.turns["turn-1"],
        invocation,
        projection
      )

    assert Enum.map(context, & &1.role) == [:user, :user, :assistant]
    assert Enum.at(context, 1).content =~ "Use the smaller approach"
    assert List.last(context).content == "Revised answer"
  end

  test "queued Turn records distinguish follow-ups from ordinary input" do
    projection =
      Projector.replay([
        event(1, :room_created, room_data()),
        event(2, :message_posted, message_data()),
        event(3, :turn_queued, turn_data("follow_up"))
      ])

    assert projection.turns["turn-1"].input_kind == :follow_up
  end

  defp base_events do
    [
      event(1, :room_created, room_data()),
      event(2, :message_posted, message_data()),
      event(3, :turn_queued, turn_data("operator")),
      event(4, :assistant_message_opened, %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "participant" => %{
          "id" => "primary",
          "name" => "Assistant",
          "perspective" => "coding",
          "provider" => "simulator",
          "model" => nil,
          "kind" => "primary"
        },
        "stage" => 0,
        "label" => "answer",
        "system_prompt" => "Answer",
        "attempt" => 1
      }),
      event(5, :invocation_steering_requested, %{
        "invocation_id" => "inv-1",
        "message_id" => "msg-assistant",
        "turn_id" => "turn-1",
        "room_id" => "room-1",
        "steering_id" => "steering-1",
        "body" => "Use the smaller approach"
      })
    ]
  end

  defp room_data do
    %{
      "room_id" => "room-1",
      "slug" => "room",
      "title" => "Room",
      "workspace" => System.tmp_dir!(),
      "participants" => []
    }
  end

  defp message_data do
    %{
      "message_id" => "msg-user",
      "room_id" => "room-1",
      "turn_id" => "turn-1",
      "body" => "Initial request",
      "author_name" => "You"
    }
  end

  defp turn_data(input_kind) do
    %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "user_message_id" => "msg-user",
      "mode" => "direct",
      "input_kind" => input_kind,
      "context_through_sequence" => 2,
      "participant_id" => nil
    }
  end

  defp event(sequence, type, data) do
    aggregate_id = data["invocation_id"] || data["turn_id"] || data["room_id"]
    Event.new(sequence, type, data, aggregate_type: :room, aggregate_id: aggregate_id)
  end
end
