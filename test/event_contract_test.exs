defmodule ReyCode.EventContractTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Event, EventStore}

  @metadata [aggregate_type: :room, aggregate_id: "room-1", room_id: "room-1"]

  describe "payload contracts cover every supported type" do
    test "every type declares required and optional field rules" do
      for type <- Event.types() do
        contract = Event.contract(type)
        assert match?(%{required: %{}, optional: %{}}, contract), "no contract for #{type}"
        assert contract.required != nil
      end
    end

    test "every type accepts its canonical valid payload through new/4" do
      for {type, index} <- Enum.with_index(Event.types(), 1) do
        assert %Event{type: ^type} = Event.new(index, type, valid_data(type), @metadata)
      end
    end
  end

  describe "ill-typed payloads are rejected naming the type and field" do
    test "key-complete but malformed values fail validation" do
      cases = [
        {:room_created, "participants", "not-a-list"},
        {:room_created, "title", 42},
        {:participant_added, "kind", "chief"},
        {:participant_configured, "model", 3},
        {:message_posted, "body", nil},
        {:turn_queued, "mode", "teleport"},
        {:turn_queued, "context_through_sequence", "soon"},
        {:assistant_message_opened, "participant", "builder"},
        {:assistant_message_opened, "stage", -1},
        {:assistant_message_opened, "attempt", 0},
        {:provider_frame_recorded, "frame_sequence", 1.5},
        {:provider_frame_recorded, "kind", "carrier_pigeon"},
        {:invocation_completed, "metadata", []},
        {:invocation_failed, "error", %{"category" => :boom}},
        {:invocation_cancelled, "reason", 9},
        {:turn_completed, "outcome", "victorious"},
        {:snapshot_recorded, "binary", "!!not base64!!"},
        {:squad_configured, "seats", "leader"},
        {:squad_configured, "rework_budget", 0},
        {:squad_configured, "release_authority", "nobody"},
        {:squad_stage_entered, "stage", "zero"},
        {:squad_decision_recorded, "decision", "promote"},
        {:squad_artifact_recorded, "blockers", "none"},
        {:squad_retry_scheduled, "attempt", "first"},
        {:squad_role_configured, "provider", ""},
        {:squad_directive_added, "cycle", "one"},
        {:gate_review_requested, "decision", "escalate"},
        {:gate_resolved, "cycle", -2},
        {:squad_budget_extended, "budget", nil},
        {:tool_ask_requested, "arguments", "rm -rf"},
        {:tool_ask_resolved, "decision", "defer"},
        {:provider_round_recorded, "tool_calls", %{"call" => 1}},
        {:provider_round_recorded, "usage", []},
        {:tool_run_requested, "authorization", "maybe"},
        {:tool_run_approval_resolved, "decision", "approve."},
        {:tool_run_started, "tool_run_id", ""},
        {:tool_run_completed, "result", []},
        {:tool_run_failed, "error", "timeout"},
        {:tool_run_interrupted, "reason", nil}
      ]

      for {type, field, value} <- cases do
        data = Map.put(valid_data(type), field, value)

        assert {:error, reason} = Event.validate_data(type, data)

        assert reason =~ "#{Atom.to_string(type)} event",
               "expected #{inspect(reason)} to name #{type}"

        assert reason =~ "\"#{field}\"", "expected #{inspect(reason)} to name \"#{field}\""

        assert_raise ArgumentError, ~r/#{Regex.escape(reason)}/, fn ->
          Event.new(1, type, data, @metadata)
        end
      end
    end

    test "missing fields report every absent required key" do
      assert {:error, reason} = Event.validate_data(:turn_queued, %{})

      assert reason ==
               "invalid turn_queued event: missing field(s) \"context_through_sequence\", " <>
                 "\"mode\", \"room_id\", \"turn_id\", \"user_message_id\""
    end

    test "nested participant shapes require identity fields" do
      headless = %{"name" => "Builder", "provider" => "simulator"}
      data = put_in(valid_data(:room_created), ["participants"], [headless])

      assert {:error, reason} = Event.validate_data(:room_created, data)
      assert reason =~ ~s(field "participants" must be a list of participant objects)
    end

    test "failure-shaped errors require the failure wire shape" do
      data = Map.put(valid_data(:invocation_failed), "error", %{"message" => "boom"})
      assert {:error, reason} = Event.validate_data(:invocation_failed, data)
      assert reason =~ ~s(field "error" must be a failure object)
    end
  end

  describe "cross-field payload rules" do
    test "text_delta frames require a text string inside data" do
      base = valid_data(:provider_frame_recorded)
      delta = %{base | "kind" => "text_delta", "data" => %{}}
      assert {:error, reason} = Event.validate_data(:provider_frame_recorded, delta)
      assert reason =~ ~s(text_delta frames require field "text")

      ok = %{base | "kind" => "text_delta", "data" => %{"text" => "hello"}}
      assert :ok = Event.validate_data(:provider_frame_recorded, ok)
    end

    test "rework retries require target stage, phase, and cycle" do
      base = valid_data(:squad_retry_scheduled)
      incomplete = Map.merge(base, %{"kind" => "rework"})
      assert {:error, reason} = Event.validate_data(:squad_retry_scheduled, incomplete)
      assert reason =~ "rework retries require"

      complete =
        Map.merge(base, %{
          "kind" => "rework",
          "target_stage" => 0,
          "target_phase" => "leader_intake",
          "cycle" => 1
        })

      assert :ok = Event.validate_data(:squad_retry_scheduled, complete)
    end
  end

  describe "schema-v2 legacy compatibility" do
    test "events written before optional fields existed still decode" do
      sparse_turn = Map.delete(valid_data(:turn_queued), "participant_id")

      assert %Event{type: :turn_queued} =
               Event.decode_value!(wire_event(:turn_queued, sparse_turn))

      sparse_invocation =
        valid_data(:assistant_message_opened)
        |> Map.drop(["phase", "cycle", "logical_work_id", "dependencies", "attempt"])

      assert %Event{type: :assistant_message_opened} =
               Event.decode_value!(wire_event(:assistant_message_opened, sparse_invocation))
    end

    test "unknown extra fields do not break decoding of older events" do
      extended =
        valid_data(:message_posted)
        |> Map.put("author_name", "You")
        |> Map.put("legacy_note", "written by an older release")

      assert %Event{type: :message_posted} =
               Event.decode_value!(wire_event(:message_posted, extended))
    end
  end

  test "malformed entries are rejected before any durable write" do
    path = tmp_path("contract-reject.sqlite3")
    {store, id} = start_store(path)

    entries = [
      {:room_created, valid_data(:room_created), @metadata},
      {:turn_queued, Map.put(valid_data(:turn_queued), "mode", "teleport"), @metadata}
    ]

    assert {:error, {:invalid_event, :turn_queued, reason}} =
             EventStore.append_many(entries, store)

    assert reason =~ ~s(field "mode")

    assert [] == EventStore.load(store)

    stop_supervised!(id)
  end

  defp valid_data(:room_created),
    do: %{
      "room_id" => "room-1",
      "slug" => "alpha",
      "title" => "Alpha",
      "workspace" => "/tmp/alpha",
      "participants" => [
        %{
          "id" => "primary",
          "name" => "Primary",
          "perspective" => "lead",
          "provider" => "simulator",
          "model" => "test-model",
          "kind" => "primary"
        }
      ]
    }

  defp valid_data(:participant_added),
    do: %{
      "room_id" => "room-1",
      "participant_id" => "task-1",
      "name" => "Task",
      "responsibility" => "research",
      "provider" => "simulator",
      "model" => "test-model",
      "kind" => "task"
    }

  defp valid_data(:participant_configured),
    do: %{
      "room_id" => "room-1",
      "participant_id" => "task-1",
      "provider" => "simulator",
      "model" => "test-model"
    }

  defp valid_data(:message_posted),
    do: %{
      "message_id" => "msg-1",
      "room_id" => "room-1",
      "turn_id" => "turn-1",
      "body" => "Hello",
      "author_name" => "You"
    }

  defp valid_data(:turn_queued),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "user_message_id" => "msg-1",
      "mode" => "direct",
      "context_through_sequence" => 1,
      "participant_id" => nil
    }

  defp valid_data(:turn_started),
    do: %{"turn_id" => "turn-1", "room_id" => "room-1"}

  defp valid_data(:assistant_message_opened),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "participant" => %{
        "id" => "primary",
        "name" => "Primary",
        "perspective" => "lead",
        "provider" => "simulator",
        "model" => "test-model",
        "kind" => "primary"
      },
      "stage" => 0,
      "label" => "response",
      "system_prompt" => "Answer",
      "phase" => "answer",
      "cycle" => 0,
      "logical_work_id" => "work-1",
      "dependencies" => [],
      "attempt" => 1
    }

  defp valid_data(:invocation_started),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1"
    }

  defp valid_data(:provider_frame_recorded),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "frame_sequence" => 1,
      "kind" => "usage",
      "data" => %{"usage" => %{"total_tokens" => 10}}
    }

  defp valid_data(:invocation_completed),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "metadata" => %{"finish_reason" => "stop"}
    }

  defp valid_data(:invocation_failed),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "error" => %{"category" => "provider_error", "message" => "boom", "retryable" => false}
    }

  defp valid_data(:invocation_cancelled),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "reason" => "user requested"
    }

  defp valid_data(:turn_completed),
    do: %{"turn_id" => "turn-1", "room_id" => "room-1", "outcome" => "completed"}

  defp valid_data(:snapshot_recorded),
    do: %{"binary" => Base.encode64(:erlang.term_to_binary(%{sequence: 0}))}

  defp valid_data(:squad_configured),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "seats" => ["squad_leader"],
      "rework_budget" => 2,
      "release_authority" => "human",
      "workflow_version" => "squad-v1",
      "phase" => "leader_intake"
    }

  defp valid_data(:squad_stage_entered),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "stage" => 1,
      "phase" => "build",
      "cycle" => 0
    }

  defp valid_data(:squad_decision_recorded),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "seat_id" => "squad_leader",
      "decision" => "approve",
      "phase" => "build",
      "cycle" => 0,
      "target_phase" => nil,
      "reasons" => []
    }

  defp valid_data(:squad_artifact_recorded),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "seat_id" => "squad_leader",
      "kind" => "plan",
      "phase" => "plan",
      "cycle" => 0,
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "summary" => "did the thing",
      "blockers" => [],
      "digest" => "abc123"
    }

  defp valid_data(:squad_retry_scheduled),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "seat_id" => "squad_leader",
      "attempt" => 2,
      "kind" => "provider_retry",
      "phase" => "build",
      "cycle" => 0,
      "reason" => "rate_limit"
    }

  defp valid_data(:squad_role_configured),
    do: %{
      "room_id" => "room-1",
      "role_id" => "squad_leader",
      "name" => "Leader",
      "perspective" => "coordinate",
      "provider" => "simulator",
      "model" => "test-model"
    }

  defp valid_data(:squad_directive_added),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "text" => "focus on tests",
      "phase" => "build",
      "cycle" => 0
    }

  defp valid_data(:gate_review_requested),
    do: %{
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "seat_id" => "squad_leader",
      "decision" => "approve",
      "phase" => "release_gate",
      "cycle" => 0,
      "target_phase" => nil,
      "reasons" => []
    }

  defp valid_data(:gate_resolved), do: valid_data(:gate_review_requested)

  defp valid_data(:squad_budget_extended),
    do: %{"turn_id" => "turn-1", "room_id" => "room-1", "budget" => 3}

  defp valid_data(:tool_ask_requested),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "request_id" => "req-1",
      "tool" => "shell",
      "arguments" => %{"command" => "ls"},
      "workspace" => "/tmp/alpha"
    }

  defp valid_data(:tool_ask_resolved),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "request_id" => "req-1",
      "tool" => "shell",
      "decision" => "approve"
    }

  defp valid_data(:provider_round_recorded),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "round_index" => 0,
      "text" => "working",
      "tool_calls" => [],
      "usage" => nil
    }

  defp valid_data(:tool_run_requested),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "tool_run_id" => "run-1",
      "tool_call_id" => "call-1",
      "round_index" => 0,
      "tool" => "shell",
      "arguments" => %{"command" => "ls"},
      "workspace" => "/tmp/alpha",
      "authorization" => "ask"
    }

  defp valid_data(:tool_run_approval_resolved),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "tool_run_id" => "run-1",
      "tool" => "shell",
      "decision" => "deny"
    }

  defp valid_data(:tool_run_started),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "tool_run_id" => "run-1",
      "tool" => "shell"
    }

  defp valid_data(:tool_run_completed),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "tool_run_id" => "run-1",
      "tool" => "shell",
      "result" => %{"ok" => true}
    }

  defp valid_data(:tool_run_failed),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "tool_run_id" => "run-1",
      "tool" => "shell",
      "error" => %{"ok" => false, "error" => "exit_1"},
      "result" => %{"ok" => false, "error" => "exit_1"}
    }

  defp valid_data(:tool_run_interrupted),
    do: %{
      "invocation_id" => "inv-1",
      "message_id" => "msg-2",
      "turn_id" => "turn-1",
      "room_id" => "room-1",
      "tool_run_id" => "run-1",
      "tool" => "shell",
      "reason" => "worker exit"
    }

  defp wire_event(type, data) do
    %{
      "id" => Integer.to_string(7),
      "sequence" => 7,
      "schema_version" => Event.schema_version(),
      "type" => Atom.to_string(type),
      "aggregate_type" => "room",
      "aggregate_id" => "room-1",
      "room_id" => "room-1",
      "correlation_id" => nil,
      "causation_id" => nil,
      "data" => data,
      "recorded_at" => "2026-01-01T00:00:00.000Z"
    }
  end

  defp tmp_path(filename) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "rey_code_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, filename)
  end

  defp start_store(path) do
    File.mkdir_p!(Path.dirname(path))
    id = {EventStore, System.unique_integer([:positive])}
    spec = Supervisor.child_spec({EventStore, [name: nil, path: path]}, id: id)
    {start_supervised!(spec), id}
  end
end
