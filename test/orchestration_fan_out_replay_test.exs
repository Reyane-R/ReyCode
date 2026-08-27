defmodule ReyCode.Orchestration.FanOutReplayTest do
  @moduledoc """
  Replay fixture for the retired fan_out mode.

  The mode left the live registry, but historical events still carry its
  wire value. This seeds one complete fan_out turn directly into a fresh
  EventStore — the exact shape an old database holds — and proves the
  projector replays it inertly while admission rejects the retired ID.
  """

  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}

  alias ReyCode.Orchestration.{
    Engine,
    EventEntries,
    Invocation,
    Participant,
    Projector,
    Room,
    Turn
  }

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor
  @engine __MODULE__.Engine

  test "a complete historical fan_out turn replays end-to-end and stays inert" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_fanout_replay_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    room_id = "room-fanout-legacy"
    turn_id = "turn-fanout-legacy"

    explorer = %Participant{
      id: "explorer",
      name: "Explorer",
      perspective: "exploration",
      provider: :simulator,
      model: nil,
      kind: :primary
    }

    turn = %Turn{id: turn_id, room_id: room_id}

    invocation = %Invocation{
      id: "inv-fanout",
      room_id: room_id,
      turn_id: turn_id,
      message_id: "msg-fanout",
      participant: explorer,
      phase_index: 0,
      label: "parallel branch",
      system_prompt: "Explore one design independently",
      attempt: 1
    }

    entries =
      [
        EventEntries.room_created(
          room_id,
          "fanout-legacy",
          "Fan out legacy",
          System.tmp_dir!(),
          [participant_wire(explorer)]
        )
      ] ++
        EventEntries.queue_turn(
          room_id,
          "Explore three designs",
          :fan_out,
          turn_id,
          "msg-user-fanout",
          2,
          :operator,
          nil
        ) ++
        [EventEntries.turn_started(turn)] ++
        EventEntries.open_invocations(
          %Room{id: room_id},
          turn,
          [
            %{
              participant_id: explorer.id,
              participant: explorer,
              phase_index: 0,
              label: "parallel branch",
              system_prompt: "Explore one design independently",
              attempt: 1
            }
          ],
          [{"inv-fanout", "msg-fanout"}]
        ) ++
        [
          EventEntries.invocation_started(invocation),
          EventEntries.provider_round(invocation, 0, %{
            "text" => "Design one: event-sourced rooms.",
            "tool_calls" => [],
            "usage" => nil
          }),
          EventEntries.invocation_terminal(
            invocation,
            {:completed, %{"finish_reason" => "stop"}}
          ),
          EventEntries.turn_completed(turn, :completed)
        ]

    assert {:ok, _events} = EventStore.append_many(entries, store)

    # Direct projection: the retired wire value decodes to the inert legacy
    # marker instead of raising.
    projection = store |> EventStore.load() |> Projector.replay()
    projected = projection.turns[turn_id]

    assert projected.mode == :fan_out
    assert projected.outcome == :completed

    # A live engine boots on the same history without raising.
    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: ReyCode.Provider.Catalog,
       config: RuntimeConfig.fresh(allow_simulator_provider: true),
       agent_delay_ms: 0}
    )

    snapshot = Engine.snapshot(@engine)
    assert snapshot.turns[turn_id].mode == :fan_out
    assert snapshot.turns[turn_id].outcome == :completed

    # Admission still fails closed for the retired mode.
    assert {:error, :invalid_mode} =
             Engine.post_message(room_id, "Fan out again", :fan_out, @engine)
  end

  test "queued and active historical fan_out turns terminate without dispatch on recovery" do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_fanout_unfinished_#{System.pid()}_#{System.unique_integer([:positive])}.sqlite3"
      )

    store = start_supervised!({EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    explorer = %Participant{
      id: "explorer",
      name: "Explorer",
      perspective: "exploration",
      provider: :simulator,
      model: nil,
      kind: :primary
    }

    queued_turn = %Turn{id: "turn-fanout-queued", room_id: "room-fanout-queued"}
    active_turn = %Turn{id: "turn-fanout-active", room_id: "room-fanout-active"}

    active_invocation = %Invocation{
      id: "inv-fanout-active",
      room_id: active_turn.room_id,
      turn_id: active_turn.id,
      message_id: "msg-fanout-active",
      participant: explorer,
      phase_index: 0,
      label: "parallel branch",
      system_prompt: "Explore independently",
      attempt: 1
    }

    entries =
      room_and_queue_entries(queued_turn, explorer, "queued") ++
        room_and_queue_entries(active_turn, explorer, "active") ++
        [EventEntries.turn_started(active_turn)] ++
        EventEntries.open_invocations(
          %Room{id: active_turn.room_id},
          active_turn,
          [
            %{
              participant_id: explorer.id,
              participant: explorer,
              phase_index: 0,
              label: "parallel branch",
              system_prompt: "Explore independently",
              attempt: 1
            }
          ],
          [{active_invocation.id, active_invocation.message_id}]
        ) ++
        [EventEntries.invocation_started(active_invocation)]

    assert {:ok, _events} = EventStore.append_many(entries, store)

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_supervisor: @agent_supervisor,
       agent_registry: @agent_registry,
       event_registry: @event_registry,
       provider_catalog: ReyCode.Provider.Catalog,
       config: RuntimeConfig.fresh(allow_simulator_provider: true),
       agent_delay_ms: 0}
    )

    snapshot = Engine.snapshot(@engine)
    assert snapshot.turns[queued_turn.id].status == :terminal
    assert snapshot.turns[queued_turn.id].outcome == :failed
    assert snapshot.turns[active_turn.id].status == :terminal
    assert snapshot.turns[active_turn.id].outcome == :failed
    assert snapshot.invocations[active_invocation.id].status == :cancelled
  end

  defp room_and_queue_entries(turn, participant, suffix) do
    [
      EventEntries.room_created(
        turn.room_id,
        "fanout-#{suffix}",
        "Fan out #{suffix}",
        System.tmp_dir!(),
        [participant_wire(participant)]
      )
    ] ++
      EventEntries.queue_turn(
        turn.room_id,
        "Explore #{suffix}",
        :fan_out,
        turn.id,
        "msg-user-#{suffix}",
        2,
        :operator,
        nil
      )
  end

  defp participant_wire(participant) do
    %{
      "id" => participant.id,
      "name" => participant.name,
      "perspective" => participant.perspective,
      "provider" => "simulator",
      "model" => nil
    }
  end
end
