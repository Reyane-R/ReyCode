defmodule ReyCode.Orchestration.Engine.AdmissionTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine.Admission

  defp state(overrides \\ %{}) do
    base = %{
      projection: %{
        invocations: %{},
        rooms: %{},
        turns: %{}
      },
      execution_queue: [],
      queued_execution_ids: MapSet.new(),
      active_executions: %{},
      limits: %{
        global_concurrency: 1,
        workspace_concurrency: 1,
        global_queue_limit: :infinity,
        workspace_queue_limit: :infinity
      }
    }

    Map.merge(base, Map.new(overrides))
  end

  describe "enqueue/2" do
    test "appends an eligible invocation to the queue" do
      state = state(projection: %{invocations: %{"inv-1" => %{status: :queued}}})

      result = Admission.enqueue(state, "inv-1")

      assert result.execution_queue == ["inv-1"]
      assert MapSet.member?(result.queued_execution_ids, "inv-1")
    end

    test "does not enqueue terminal invocations" do
      state = state(projection: %{invocations: %{"inv-1" => %{status: :completed}}})

      assert Admission.enqueue(state, "inv-1") == state
    end

    test "does not enqueue twice" do
      state =
        state(projection: %{invocations: %{"inv-1" => %{status: :queued}}})
        |> Admission.enqueue("inv-1")

      assert Admission.enqueue(state, "inv-1") == state
    end
  end

  describe "next_eligible/1" do
    test "returns the first queued invocation with capacity" do
      state =
        state(
          projection: %{
            invocations: %{
              "inv-1" => %{status: :queued, room_id: "room-1"},
              "inv-2" => %{status: :queued, room_id: "room-1"}
            },
            rooms: %{"room-1" => %{workspace: "/first"}}
          }
        )
        |> Admission.enqueue("inv-1")
        |> Admission.enqueue("inv-2")

      assert Admission.next_eligible(state) == {"inv-1", 0}
    end

    test "returns nil when the global limit is reached" do
      state =
        state(
          projection: %{invocations: %{"inv-1" => %{status: :queued}}, rooms: %{}},
          active_executions: %{"inv-0" => "/workspace"}
        )
        |> Admission.enqueue("inv-1")

      assert Admission.next_eligible(state) == nil
    end

    test "returns nil when the workspace limit is reached" do
      state =
        state(
          projection: %{
            invocations: %{"inv-1" => %{status: :queued, room_id: "room-1"}},
            rooms: %{"room-1" => %{workspace: "/same"}}
          },
          active_executions: %{"inv-0" => "/same"}
        )
        |> Admission.enqueue("inv-1")

      assert Admission.next_eligible(state) == nil
    end
  end

  describe "admit_turn/2" do
    test "allows a turn that can start even when queue limits are zero" do
      room = %{active_turn_id: nil, workspace: "/workspace"}

      state =
        state(
          projection: %{invocations: %{}, rooms: %{}, turns: %{}},
          limits: %{
            global_concurrency: 1,
            workspace_concurrency: 1,
            global_queue_limit: 0,
            workspace_queue_limit: 0
          }
        )

      assert Admission.admit_turn(room, state) == :ok
    end

    test "rejects a full global queue before a full workspace queue" do
      room = %{active_turn_id: "turn-active", workspace: "/workspace"}

      state =
        state(
          projection: %{
            invocations: %{},
            rooms: %{"room-1" => room},
            turns: %{"turn-queued" => %{status: :queued, room_id: "room-1"}}
          },
          limits: %{
            global_concurrency: 1,
            workspace_concurrency: 1,
            global_queue_limit: 1,
            workspace_queue_limit: 1
          }
        )

      assert Admission.admit_turn(room, state) == {:error, :global_queue_full}
    end

    test "counts only waiting work in the room workspace for its queue limit" do
      room = %{active_turn_id: "turn-active", workspace: "/workspace"}

      state =
        state(
          projection: %{
            invocations: %{
              "inv-same" => %{status: :queued, room_id: "room-1"},
              "inv-other" => %{status: :queued, room_id: "room-2"}
            },
            rooms: %{
              "room-1" => room,
              "room-2" => %{workspace: "/other"}
            },
            turns: %{}
          },
          execution_queue: ["inv-other", "inv-same"],
          queued_execution_ids: MapSet.new(["inv-other", "inv-same"]),
          limits: %{
            global_concurrency: 1,
            workspace_concurrency: 1,
            global_queue_limit: 10,
            workspace_queue_limit: 1
          }
        )

      assert Admission.admit_turn(room, state) == {:error, :workspace_queue_full}
    end
  end

  describe "execution queue removal" do
    test "dequeues the selected entry and leaves active execution tracking unchanged" do
      state =
        state(
          execution_queue: ["inv-1", "inv-2"],
          queued_execution_ids: MapSet.new(["inv-1", "inv-2"]),
          active_executions: %{"inv-active" => "/workspace"}
        )

      result = Admission.dequeue(state, {"inv-2", 1})

      assert result.execution_queue == ["inv-1"]
      assert result.queued_execution_ids == MapSet.new(["inv-1"])
      assert result.active_executions == state.active_executions
    end

    test "drops all selected IDs from queued and active execution tracking" do
      state =
        state(
          execution_queue: ["inv-1", "keep", "inv-2"],
          queued_execution_ids: MapSet.new(["inv-1", "keep", "inv-2"]),
          active_executions: %{"inv-1" => "/one", "keep" => "/two"}
        )

      result = Admission.drop_executions(state, ["inv-1", "inv-2"])

      assert result.execution_queue == ["keep"]
      assert result.queued_execution_ids == MapSet.new(["keep"])
      assert result.active_executions == %{"keep" => "/two"}
    end
  end

  describe "workspace/2" do
    test "expands the room workspace" do
      state =
        state(
          projection: %{
            invocations: %{"inv-1" => %{room_id: "room-1"}},
            rooms: %{"room-1" => %{workspace: "/tmp/ws"}}
          }
        )

      assert Admission.workspace(state, "inv-1") == Path.expand("/tmp/ws")
    end

    test "returns unknown for a missing room" do
      assert Admission.workspace(state(), "inv-1") == "unknown"
    end
  end

  describe "limit_available?/2" do
    test "infinity never rejects" do
      assert Admission.limit_available?(10_000, :infinity)
    end

    test "compares current usage against a finite limit" do
      assert Admission.limit_available?(0, 1)
      refute Admission.limit_available?(1, 1)
    end
  end
end
