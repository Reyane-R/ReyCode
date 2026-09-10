defmodule ReyCode.Orchestration.VerifiedChangeTest do
  use ExUnit.Case, async: true

  alias ReyCode.{Event, EventStore, Hashing, RuntimeConfig}
  alias ReyCode.EventStore.SQLite.Checkpoint
  alias ReyCode.Orchestration.{Engine, Projection, Projector, Session, VerifiedChange}

  defp wire(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "change-1",
        "phase" => "preparing",
        "source_workspace" => "/source",
        "workspace" => "/work",
        "base_commit" => "base",
        "prompt" => "Fix it",
        "commands" => ["mix test"],
        "max_repair_count" => 3,
        "repair_count" => 0,
        "timeout_ms" => 3_600_000,
        "check_timeout_ms" => 600_000
      },
      overrides
    )
  end

  defp check(overrides \\ %{}) do
    Map.merge(
      %{
        "command" => "mix test",
        "exit_code" => 0,
        "output" => "passed",
        "error" => nil,
        "snapshot_hash" => Hashing.sha256_hex("base\n")
      },
      overrides
    )
  end

  defp record(phase, overrides \\ %{}) do
    evidence =
      if phase in ~w(preparing baseline blocked), do: %{}, else: %{"baseline" => [check()]}

    {:ok, record} =
      wire(Map.merge(evidence, Map.put(overrides, "phase", phase))) |> VerifiedChange.from_wire()

    record
  end

  test "normalizes defaults and round-trips a typed record" do
    assert {:ok, %VerifiedChange{} = record} = VerifiedChange.from_wire(wire())
    assert record.baseline == []
    assert record.checks == []
    assert record.patch == ""
    assert record.patch_hash == nil
    assert {:ok, ^record} = record |> VerifiedChange.to_wire() |> VerifiedChange.from_wire()
    assert record == record |> Map.from_struct() |> VerifiedChange.from_map()
    assert VerifiedChange.from_map(nil) == nil
    assert Session.from_map(%{id: "old"}).verified_change == nil
  end

  test "rejects malformed, unknown, oversized, and non-string-keyed fields" do
    invalid = [
      {"id", ""},
      {"workspace", nil},
      {"source_workspace", 1},
      {"base_commit", <<255>>},
      {"phase", "done"},
      {"prompt", String.duplicate("p", 100_001)},
      {"commands", []},
      {"commands", List.duplicate("test", 9)},
      {"commands", [String.duplicate("c", 4097)]},
      {"commands", [1]},
      {"max_repair_count", 4},
      {"repair_count", -1},
      {"repair_count", 1.0},
      {"timeout_ms", 0},
      {"timeout_ms", 3_600_001},
      {"check_timeout_ms", 600_001},
      {"patch", String.duplicate("p", 2 * 1024 * 1024 + 1)},
      {"patch", nil},
      {"patch_hash", 1},
      {"error", String.duplicate("e", 4001)},
      {"baseline", nil},
      {"checks", %{}},
      {"unknown", "field"},
      {:id, "atom"}
    ]

    for {field, value} <- invalid do
      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(Map.put(wire(), field, value)),
             inspect(field)
    end

    for value <- [nil, [], "record", %VerifiedChange{}, Map.delete(wire(), "id")] do
      assert {:error, :invalid_verified_change} = VerifiedChange.from_wire(value)
    end

    assert {:error, :invalid_verified_change} =
             VerifiedChange.from_wire(wire(%{"max_repair_count" => 0, "repair_count" => 1}))

    assert {:ok, _record} =
             VerifiedChange.from_wire(
               wire(%{
                 "patch" => String.duplicate("p", 2 * 1024 * 1024),
                 "prompt" => String.duplicate("p", 100_000),
                 "commands" => List.duplicate(String.duplicate("c", 4096), 8)
               })
             )
  end

  test "check maps are exact, bounded and ordered against the command contract" do
    invalid = [
      Map.delete(check(), "error"),
      Map.put(check(), "extra", 1),
      check(%{"command" => "different"}),
      check(%{"exit_code" => "0"}),
      check(%{"output" => String.duplicate("x", 16_385)}),
      check(%{"error" => 1}),
      check(%{"snapshot_hash" => ""}),
      check(%{"snapshot_hash" => nil}),
      "check"
    ]

    for report <- invalid do
      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(wire(%{"phase" => "baseline", "baseline" => [report]}))
    end

    assert {:error, :invalid_verified_change} =
             VerifiedChange.from_wire(
               wire(%{"phase" => "baseline", "baseline" => List.duplicate(check(), 9)})
             )

    assert {:ok, _record} =
             VerifiedChange.from_wire(
               wire(%{
                 "phase" => "baseline",
                 "baseline" => [
                   check(%{
                     "exit_code" => nil,
                     "output" => String.duplicate("x", 16_384),
                     "error" => "timeout"
                   })
                 ]
               })
             )
  end

  test "initial state, forward phases, bounded repairs, and terminal immutability" do
    preparing = record("preparing")
    baseline = record("baseline")
    implementing = record("implementing")
    verifying = record("verifying")
    repairing = record("repairing", %{"repair_count" => 1})
    reverified = record("verifying", %{"repair_count" => 1})

    ready =
      record("ready", %{
        "repair_count" => 1,
        "checks" => [check()],
        "patch_hash" => Hashing.sha256_hex("base\n")
      })

    for {previous, next} <- [
          {nil, preparing},
          {preparing, baseline},
          {baseline, implementing},
          {implementing, verifying},
          {verifying, repairing},
          {repairing, repairing},
          {repairing, reverified},
          {reverified, ready}
        ] do
      assert :ok = VerifiedChange.transition(previous, next)
    end

    for {previous, next} <- [
          {nil, baseline},
          {preparing, verifying},
          {baseline, preparing},
          {implementing, ready},
          {verifying, record("repairing")},
          {repairing, verifying},
          {verifying, record("repairing", %{"repair_count" => 2})}
        ] do
      assert {:error, :invalid_verified_change_transition} =
               VerifiedChange.transition(previous, next)
    end

    for previous <- [preparing, baseline, implementing, verifying, repairing] do
      blocked = %{previous | phase: "blocked", error: "Interrupted in #{previous.phase}"}
      assert :ok = VerifiedChange.transition(previous, blocked)
      assert {:error, :verified_change_terminal} = VerifiedChange.transition(blocked, preparing)
    end

    assert {:error, :verified_change_terminal} = VerifiedChange.transition(ready, ready)

    assert {:error, :verified_change_terminal} =
             VerifiedChange.transition(ready, %{preparing | id: "new"})
  end

  test "freezes identity, contract, workspaces and completed baseline" do
    preparing = record("preparing")

    for field <-
          ~w(id source_workspace workspace base_commit prompt commands max_repair_count timeout_ms check_timeout_ms)a do
      next = Map.put(record("baseline"), field, :changed)

      assert {:error, :verified_change_contract_changed} =
               VerifiedChange.transition(preparing, next)
    end

    assert {:error, :verified_change_baseline_changed} =
             VerifiedChange.transition(
               record("implementing"),
               record("verifying", %{"baseline" => [check(%{"output" => "different"})]})
             )
  end

  test "preparing receipt resolves its commit exactly once before baseline" do
    preparing = record("preparing", %{"base_commit" => nil})
    resolved = record("preparing")
    assert :ok = VerifiedChange.transition(nil, preparing)
    assert :ok = VerifiedChange.transition(preparing, resolved)
    assert :ok = VerifiedChange.transition(resolved, record("baseline"))

    assert {:error, :verified_change_contract_changed} =
             VerifiedChange.transition(resolved, preparing)

    assert {:error, :verified_change_contract_changed} =
             VerifiedChange.transition(preparing, record("baseline"))

    for phase <- ~w(baseline implementing verifying repairing ready) do
      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(wire(%{"base_commit" => nil, "phase" => phase}))
    end

    interrupted = %{preparing | phase: "blocked", error: "Interrupted before Git inspection"}
    assert :ok = VerifiedChange.transition(preparing, interrupted)
    assert {:ok, ^interrupted} = VerifiedChange.from_wire(VerifiedChange.to_wire(interrupted))
  end

  test "admits exactly three repair cycles and rejects repair budget exhaustion" do
    final =
      Enum.reduce(1..3, record("verifying"), fn count, previous ->
        repairing = record("repairing", %{"repair_count" => count})
        verifying = record("verifying", %{"repair_count" => count})
        assert :ok = VerifiedChange.transition(previous, repairing)
        assert :ok = VerifiedChange.transition(repairing, verifying)
        verifying
      end)

    assert {:error, :invalid_verified_change_transition} =
             VerifiedChange.transition(final, record("repairing", %{"repair_count" => 3}))

    assert {:error, :invalid_verified_change} =
             VerifiedChange.from_wire(
               wire(%{"phase" => "repairing", "baseline" => [check()], "repair_count" => 4})
             )
  end

  test "ready requires executed baseline and successful final reports bound to the retained patch" do
    ready =
      wire(%{
        "phase" => "ready",
        "baseline" => [check()],
        "checks" => [check()],
        "patch_hash" => Hashing.sha256_hex("base\n")
      })

    assert {:ok, _record} = VerifiedChange.from_wire(ready)

    assert {:ok, _record} =
             VerifiedChange.from_wire(Map.put(ready, "baseline", [check(%{"exit_code" => 1})]))

    for {field, value} <- [
          {"baseline", []},
          {"baseline", [check(%{"exit_code" => nil})]},
          {"baseline", [check(%{"error" => "timeout"})]},
          {"checks", []},
          {"checks", [check(%{"exit_code" => nil})]},
          {"checks", [check(%{"error" => "failed"})]},
          {"checks", [check(%{"snapshot_hash" => "stale"})]},
          {"patch_hash", nil},
          {"patch", "different patch"},
          {"error", "failed"}
        ] do
      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(Map.put(ready, field, value))
    end

    assert {:error, :invalid_verified_change} =
             VerifiedChange.from_wire(wire(%{"phase" => "blocked"}))
  end

  test "workflow, analysis, and metadata default to nil, round-trip, and validate strictly" do
    assert %{workflow: nil, analysis: nil, metadata: nil} =
             elem(VerifiedChange.from_wire(wire()), 1)

    workflow = %{"testing" => %{"provider" => "deepseek", "model" => "deepseek-chat"}}

    stage = %{
      "outcome" => "completed",
      "response" => "focus on index 1",
      "turn_id" => "turn-9",
      "error" => nil
    }

    assert {:ok, record} =
             VerifiedChange.from_wire(wire(%{"workflow" => workflow, "analysis" => stage}))

    assert record.workflow == workflow
    assert record.analysis == stage
    assert {:ok, ^record} = record |> VerifiedChange.to_wire() |> VerifiedChange.from_wire()

    unavailable = %{
      "outcome" => "unavailable",
      "response" => "",
      "turn_id" => nil,
      "error" => "timeout"
    }

    assert {:ok, _record} =
             VerifiedChange.from_wire(wire(%{"metadata" => unavailable}))

    invalid_workflows = [
      %{"testing" => %{"provider" => "deepseek"}},
      %{"testing" => %{"provider" => "deepseek", "model" => ""}},
      %{"testing" => %{"provider" => "", "model" => "m"}},
      %{"testing" => %{"provider" => "d", "model" => "m", "extra" => "x"}},
      %{"audit" => %{"provider" => "d", "model" => "m"}},
      %{"testing" => %{"provider" => "d", "model" => "m"}, "release" => :simulator},
      %{"testing" => [:not, :a, :map]},
      {:%{}, :invalid}
    ]

    for value <- invalid_workflows do
      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(wire(%{"workflow" => value}))
    end

    assert {:error, :invalid_verified_change} =
             VerifiedChange.from_wire(
               wire(%{
                 "analysis" => Map.put(stage, "response", String.duplicate("r", 16_385))
               })
             )

    for value <- [
          Map.put(stage, "outcome", "approved"),
          Map.put(stage, "extra", 1),
          Map.delete(stage, "turn_id"),
          Map.put(stage, "error", String.duplicate("e", 4001)),
          Map.put(stage, "turn_id", 7)
        ] do
      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(wire(%{"analysis" => value}))

      assert {:error, :invalid_verified_change} =
               VerifiedChange.from_wire(wire(%{"metadata" => value}))
    end
  end

  test "workflow is frozen and report-only stage phases advance legally" do
    workflow = %{
      "testing" => %{"provider" => "simulator", "model" => "test-model"},
      "release" => %{"provider" => "simulator", "model" => "release-model"}
    }

    verifying = record("verifying", %{"workflow" => workflow})
    analyzing = record("analyzing", %{"workflow" => workflow, "analysis" => nil})

    repaired =
      record("repairing", %{
        "workflow" => workflow,
        "repair_count" => 1,
        "analysis" => %{
          "outcome" => "completed",
          "response" => "check 1 failed",
          "turn_id" => "turn-1",
          "error" => nil
        }
      })

    assert :ok = VerifiedChange.transition(verifying, analyzing)
    assert :ok = VerifiedChange.transition(analyzing, repaired)

    assert {:error, :verified_change_contract_changed} =
             VerifiedChange.transition(
               verifying,
               record("analyzing", %{
                 "workflow" => %{"testing" => %{"provider" => "other", "model" => "m"}}
               })
             )

    releasing = record("releasing", %{"workflow" => workflow})
    assert :ok = VerifiedChange.transition(verifying, releasing)

    ready =
      record("ready", %{
        "workflow" => workflow,
        "checks" => [check()],
        "patch_hash" => Hashing.sha256_hex("base\n"),
        "metadata" => %{
          "outcome" => "completed",
          "response" => "subject: fix",
          "turn_id" => "turn-2",
          "error" => nil
        }
      })

    assert :ok = VerifiedChange.transition(releasing, ready)
    assert :ok = VerifiedChange.transition(releasing, %{ready | metadata: nil})

    assert {:error, :invalid_verified_change_transition} =
             VerifiedChange.transition(analyzing, record("verifying", %{"workflow" => workflow}))

    assert {:error, :invalid_verified_change_transition} =
             VerifiedChange.transition(
               releasing,
               record("repairing", %{"workflow" => workflow, "repair_count" => 1})
             )
  end

  @tag :tmp_dir
  test "Engine journals before work, rejects without append, and restores checkpoint plus tail",
       %{tmp_dir: dir} do
    config =
      RuntimeConfig.fresh(
        allow_simulator_provider: true,
        default_provider: :simulator,
        provider_discovery: false
      )

    registry = :"verified_change_events_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry})
    store_opts = [name: nil, path: Path.join(dir, "journal.sqlite3"), config: config.persistence]
    store = start_supervised!({EventStore, store_opts})
    engine_opts = [name: nil, event_store: store, event_registry: registry, config: config]
    engine = start_supervised!({Engine, engine_opts})
    session_id = hd(Engine.snapshot(engine).session_order)
    assert :ok = Engine.record_verified_change(session_id, wire(), engine)
    preparing = Engine.snapshot(engine)
    assert preparing.sessions[session_id].verified_change.phase == "preparing"
    assert preparing.turns == %{}
    assert {:error, :session_not_found} = Engine.record_verified_change("missing", wire(), engine)

    assert {:error, :invalid_verified_change} =
             Engine.record_verified_change(session_id, %{}, engine)

    assert {:error, :invalid_verified_change_transition} =
             Engine.record_verified_change(
               session_id,
               VerifiedChange.to_wire(record("verifying")),
               engine
             )

    assert Engine.snapshot(engine) == preparing

    assert {:error, {:invalid_event, :verified_change_recorded, _reason}} =
             EventStore.append(
               :verified_change_recorded,
               %{"room_id" => session_id, "record" => %{}},
               store,
               aggregate_type: :room,
               aggregate_id: session_id,
               room_id: session_id
             )

    assert Projector.replay(EventStore.load(store)) == preparing

    skipped =
      Event.new(
        preparing.sequence + 1,
        :verified_change_recorded,
        %{"room_id" => session_id, "record" => VerifiedChange.to_wire(record("verifying"))},
        aggregate_type: :room,
        aggregate_id: session_id,
        room_id: session_id
      )

    assert_raise MatchError, fn -> Projector.apply(skipped, preparing) end

    assert :ok = EventStore.checkpoint(preparing, store)
    assert :ok = Engine.record_verified_change(session_id, wire(%{"phase" => "baseline"}), engine)
    before_restart = Engine.snapshot(engine)
    events = EventStore.load(store)
    assert Projector.replay(events) == before_restart
    journal = Enum.filter(events, &(&1.type == :verified_change_recorded))
    assert Enum.map(journal, & &1.data["record"]["phase"]) == ["preparing", "baseline"]
    assert Enum.all?(journal, &(Event.decode!(Event.encode!(&1)) == &1))
    assert {:ok, checkpoint, [_tail]} = EventStore.load_projection(store)
    assert Projection.from_map(checkpoint) == preparing

    stop_supervised!(Engine)
    stop_supervised!(EventStore)
    store = start_supervised!({EventStore, store_opts})
    engine = start_supervised!({Engine, Keyword.put(engine_opts, :event_store, store)})
    recovered = Engine.snapshot(engine)
    assert recovered.sequence == before_restart.sequence + 1
    assert recovered.sessions[session_id].verified_change.phase == "blocked"

    assert recovered.sessions[session_id].verified_change.error ==
             "Interrupted during baseline; not resumed"

    assert {:error, :verified_change_terminal} =
             Engine.record_verified_change(
               session_id,
               wire(%{
                 "phase" => "blocked",
                 "error" => "Interrupted during baseline; not resumed"
               }),
               engine
             )

    assert {:error, :verified_change_terminal} =
             Engine.record_verified_change(session_id, wire(), engine)

    assert {:ok, ready_session_id} = Engine.create_session(session_id, "Ready change", engine)

    for phase <- ~w(preparing baseline implementing verifying) do
      assert :ok =
               Engine.record_verified_change(
                 ready_session_id,
                 VerifiedChange.to_wire(record(phase)),
                 engine
               )
    end

    patch = String.duplicate("p", 2 * 1024 * 1024)
    hash = Hashing.sha256_hex("base\n" <> patch)

    ready =
      record("ready", %{
        "checks" => [check(%{"snapshot_hash" => hash})],
        "patch_hash" => hash,
        "patch" => patch
      })

    assert :ok =
             Engine.record_verified_change(
               ready_session_id,
               VerifiedChange.to_wire(ready),
               engine
             )

    completed = Engine.snapshot(engine)
    assert completed.sessions[ready_session_id].verified_change == ready
    assert :ok = EventStore.checkpoint(completed, store)
    assert {:ok, checkpoint, []} = EventStore.load_projection(store)
    assert Projection.from_map(checkpoint) == completed
    assert Projector.replay(EventStore.load(store)) == completed

    stop_supervised!(Engine)
    engine = start_supervised!({Engine, Keyword.put(engine_opts, :event_store, store)})
    assert Engine.snapshot(engine) == completed
  end

  test "checkpoint seam rejects malformed evidence and accepts old missing Session fields" do
    old = %{
      sequence: 0,
      sessions: %{"session" => %{id: "session"}},
      session_order: ["session"],
      messages: %{},
      turns: %{},
      invocations: %{}
    }

    assert {:ok, decoded} = decode_checkpoint(old)
    assert Projection.from_map(decoded).sessions["session"].verified_change == nil
    valid = put_in(old, [:sessions, "session", :verified_change], record("preparing"))
    assert {:ok, decoded} = decode_checkpoint(valid)
    assert %VerifiedChange{} = Projection.from_map(decoded).sessions["session"].verified_change
    invalid = put_in(valid, [:sessions, "session", :verified_change], %{phase: "ready"})
    assert {:error, :invalid_checkpoint} = decode_checkpoint(invalid)
  end

  defp decode_checkpoint(projection) do
    encoded = projection |> Checkpoint.encode_term() |> Jason.encode!()

    Checkpoint.decode(
      encoded,
      Checkpoint.projection_version(),
      0,
      Hashing.sha256_hex(encoded),
      16_000_000
    )
  end
end
