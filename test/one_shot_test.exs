defmodule ReyCode.OneShotTest do
  use ExUnit.Case, async: false

  alias ReyCode.CLI.Run
  alias ReyCode.OneShot
  alias ReyCode.Orchestration.{Engine, Validation}

  @stub_ok {:ok, %{outcome: :completed, response: "stub response"}}
  @stub_error {:error, %{outcome: :failed, response: "", error: "stub failure"}}

  test "parses option, positional, and piped prompts through one contract" do
    assert {:ok, %{prompt: "from option"}} = Run.parse(["-p", "from option"])
    assert {:ok, %{prompt: "from positional words"}} = Run.parse(["from", "positional", "words"])

    assert {:ok, %{prompt: "from pipe"}} =
             Run.parse([], stdin_reader: fn -> {:ok, "from pipe\n"} end)

    assert {:error, message} = Run.parse(["-p", "one", "two"])
    assert message =~ "choose either -p or positional"
  end

  test "rejects oversized piped input before orchestration" do
    oversized = String.duplicate("x", Validation.message_max_bytes() + 1)

    assert {:error, message} = Run.parse([], stdin_reader: fn -> {:ok, oversized} end)
    assert message =~ "exceeds"
  end

  test "renders orchestration startup errors without raising" do
    assert {:error, %{outcome: :failed, error: "invalid_timeout"}} =
             OneShot.run(%{
               prompt: "Do not start",
               workspace: File.cwd!(),
               timeout_ms: 0
             })
  end

  test "runs one durable Primary Assistant turn and returns its response" do
    assert {:ok, report} =
             OneShot.run(%{
               prompt: "Return a concise one-shot response",
               workspace: File.cwd!(),
               timeout_ms: 5_000
             })

    assert report.outcome == :completed
    assert report.session_id
    assert report.turn_id
    assert is_binary(report.response)
    assert report.response != ""

    snapshot = Engine.snapshot()
    assert snapshot.turns[report.turn_id].status == :terminal
  end

  test "renders machine-readable output" do
    assert {:ok, encoded} =
             Run.execute(
               ["-p", "Return JSON-compatible output", "--json", "--timeout-ms", "5000"],
               engine: Engine
             )

    assert {:ok, decoded} = Jason.decode(encoded)
    assert decoded["outcome"] == "completed"
    assert is_binary(decoded["response"])
  end

  test "execute renders injected reports without a real turn" do
    assert {:ok, "stub response"} =
             Run.execute(["-p", "ignored"],
               engine: Engine,
               runner: fn _options, _engine -> @stub_ok end
             )

    assert {:error, encoded} =
             Run.execute(["-p", "ignored", "--json"],
               engine: Engine,
               runner: fn _options, _engine -> @stub_error end
             )

    assert {:ok, decoded} = Jason.decode(encoded)
    assert decoded["outcome"] == "failed"
    assert decoded["error"] == "stub failure"
  end

  test "main prints success to stdout and exits zero" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Run.main(["-p", "ignored"], fn code -> send(self(), {:halt, code}) end,
          engine: Engine,
          runner: fn _options, _engine -> @stub_ok end
        )
      end)

    assert output == "stub response\n"
    assert_received {:halt, 0}
  end

  test "main exits nonzero on a failed report" do
    ExUnit.CaptureIO.capture_io(fn ->
      Run.main(["-p", "ignored"], fn code -> send(self(), {:halt, code}) end,
        engine: Engine,
        runner: fn _options, _engine -> @stub_error end
      )
    end)

    assert_received {:halt, 1}
  end

  test "parse rejects an empty prompt, missing workspace, and invalid timeout" do
    assert {:error, "prompt is empty\n" <> _} = Run.parse(["-p", ""])

    assert {:error, "workspace is not a directory: /no/such/dir" <> _} =
             Run.parse(["-p", "x", "--workspace", "/no/such/dir"])

    assert {:error, "--timeout-ms must be positive"} = Run.parse(["-p", "x", "--timeout-ms", "0"])
  end

  test "an unconfigured Primary Assistant fails with actionable setup guidance" do
    engine = start_unconfigured_engine()

    assert {:error, report} =
             OneShot.run(
               %{prompt: "Do the work", workspace: File.cwd!(), timeout_ms: 5_000},
               engine
             )

    assert report.outcome == :failed
    assert report.error =~ "not configured"
  end

  test "open copies the newest matching workspace primary tier, not an unrelated latest session" do
    engine = start_unconfigured_engine()
    root = Path.join(System.tmp_dir!(), "one-shot-profiles-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    target = Path.join(root, "target")
    other = Path.join(root, "other")
    Enum.each([source, target, other], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, source_id} = Engine.create_blank_session("source", source, engine)
    source_session = Engine.snapshot(engine).sessions[source_id]
    source_primary = Enum.find(source_session.participants, &(&1.kind == :primary))
    :ok = Engine.configure_participant_tier(source_id, source_primary.id, :smol, engine)
    {:ok, _other_id} = Engine.create_blank_session("other", other, engine)

    assert {:ok, target_id} =
             OneShot.open(
               %{prompt: "new", workspace: target, source_workspace: source_session.workspace},
               engine
             )

    target_session = Engine.snapshot(engine).sessions[target_id]
    assert [%{kind: :primary, model_tier: :smol}] = target_session.participants
  end

  test "run_turn validates before posting and preserves the existing session identity" do
    {:ok, session_id} = Engine.create_blank_session("OneShot existing", File.cwd!())

    assert {:error, %{session_id: ^session_id, turn_id: nil}} =
             OneShot.run_turn(session_id, "do not run", 0)

    assert {:ok, first} = OneShot.run_turn(session_id, "first", 5000)
    assert {:ok, second} = OneShot.run_turn(session_id, "second", 5000)
    assert first.session_id == session_id
    assert second.session_id == session_id
    assert first.turn_id != second.turn_id
  end

  defp start_unconfigured_engine do
    suffix = System.unique_integer([:positive])
    agent_registry = :"one_shot_agent_#{suffix}"
    event_registry = :"one_shot_events_#{suffix}"
    agent_supervisor = :"one_shot_sup_#{suffix}"
    engine_name = :"one_shot_engine_#{suffix}"

    path = Path.join(System.tmp_dir!(), "rey_code_one_shot_#{suffix}.sqlite3")

    store = start_supervised!({ReyCode.EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: event_registry})

    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: agent_supervisor})

    config = ReyCode.RuntimeConfig.fresh(default_provider: :unconfigured)

    start_supervised!(
      Supervisor.child_spec(
        {Engine,
         name: engine_name,
         event_store: store,
         agent_supervisor: agent_supervisor,
         agent_registry: agent_registry,
         event_registry: event_registry,
         provider_catalog: ReyCode.Provider.Catalog,
         config: config,
         simulator_opts: [seed: 0, delay_ms: 0, jitter_ms: 0, failure_rate: 0.0]},
        restart: :temporary
      )
    )

    engine_name
  end
end
