defmodule ReyCode.VerifiedChangeTest do
  use ExUnit.Case, async: false

  alias ReyCode.{Hashing, VerifiedChange}
  alias ReyCode.Orchestration.{DelegationWorktree, Engine}
  alias ReyCode.VerifiedChange.Worktree

  setup do
    suffix = System.unique_integer([:positive])
    source = Path.join(System.tmp_dir!(), "verified-source-#{suffix}")
    File.mkdir!(source)
    git!(source, ["init", "-q"])
    File.write!(Path.join(source, "value.txt"), "before\n")
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "-qm",
      "fixture"
    ])

    on_exit(fn -> File.rm_rf!(source) end)
    %{source: source}
  end

  test "validates all bounded option fields", %{source: source} do
    options = options(source)
    assert :ok = VerifiedChange.validate_options(options)

    for {key, value} <- [
          commands: [],
          commands: [""],
          commands: [1],
          max_repair_count: 4,
          max_repair_count: 1.0,
          timeout_ms: 0,
          check_timeout_ms: -1,
          prompt: "",
          workspace: nil
        ] do
      assert {:error, error} = VerifiedChange.validate_options(Map.put(options, key, value))
      assert is_binary(error)
    end

    assert {:error, _} = VerifiedChange.validate_options(nil)
  end

  test "runs baseline before assistant, retains a base-bound patch, and never applies source", %{
    source: source
  } do
    engine =
      engine(source, [
        %{
          tool: "edit",
          arguments: %{
            "path" => "value.txt",
            "source_hash" => Hashing.sha256_hex("before\n"),
            "patches" => [%{"old_string" => "before", "new_string" => "after"}]
          }
        }
      ])

    assert {:ok, report} =
             VerifiedChange.run(options(source, commands: ["cat value.txt"]), engine)

    retain_cleanup(report)
    assert report.outcome == :ready
    journal = Engine.snapshot(engine).sessions[report.session_id].verified_change
    assert [%{"output" => "before\n"}] = journal.baseline
    assert [%{"output" => "after\n", "snapshot_hash" => hash}] = journal.checks
    assert journal.patch =~ "+after"
    assert hash == Hashing.sha256_hex(journal.base_commit <> "\n" <> journal.patch)
    assert journal.patch_hash == hash

    assert {:ok, markdown} =
             ReyCode.SessionExport.render(Engine.snapshot(engine), report.session_id, :markdown)

    assert markdown =~ "## Verification evidence"
    assert markdown =~ hash
    assert markdown =~ Jason.encode!(journal.patch)

    assert {:ok, html} =
             ReyCode.SessionExport.render(Engine.snapshot(engine), report.session_id, :html)

    assert html =~ "Verification evidence"
    assert html =~ hash
    assert File.read!(Path.join(source, "value.txt")) == "before\n"
    assert git!(source, ["status", "--porcelain"]) == ""
    File.write!(Path.join(journal.workspace, "value.txt"), "later\n")

    assert Engine.snapshot(engine).sessions[report.session_id].verified_change.patch ==
             journal.patch

    assert report.verification["cleanup_owner"] == "caller"
  end

  test "ordinary failing baseline allows implementation and bounded repair exhaustion", %{
    source: source
  } do
    engine = engine(source)

    assert {:error, report} =
             VerifiedChange.run(
               options(source, commands: ["exit 7"], max_repair_count: 2),
               engine
             )

    retain_cleanup(report)
    assert report.error =~ "repair_exhausted"
    snapshot = Engine.snapshot(engine)
    session = snapshot.sessions[report.session_id]
    assert session.verified_change.repair_count == 2
    assert [%{"exit_code" => 7, "error" => nil}] = session.verified_change.baseline

    assert Enum.count(snapshot.turns, fn {_id, turn} -> turn.session_id == report.session_id end) ==
             3
  end

  test "blocks a check that mutates the candidate before any assistant turn", %{source: source} do
    engine = engine(source)

    assert {:error, report} =
             VerifiedChange.run(options(source, commands: ["printf changed > value.txt"]), engine)

    retain_cleanup(report)
    assert report.error =~ "mutated candidate"
    assert report.turn_id == nil
    assert Engine.snapshot(engine).sessions[report.session_id].verified_change.phase == "blocked"
    assert File.read!(Path.join(source, "value.txt")) == "before\n"
  end

  test "check timeout blocks rather than becoming an ordinary nonzero baseline", %{source: source} do
    engine = engine(source)

    assert {:error, report} =
             VerifiedChange.run(
               options(source, commands: ["sleep 2"], check_timeout_ms: 20),
               engine
             )

    retain_cleanup(report)
    assert report.error =~ "timed out"
    assert report.turn_id == nil
  end

  test "dirty source and assume-unchanged edits are rejected", %{source: source} do
    git!(source, ["update-index", "--assume-unchanged", "value.txt"])
    File.write!(Path.join(source, "value.txt"), "hidden\n")
    assert {:error, report} = VerifiedChange.run(options(source))
    assert report.session_id == nil
    assert report.error =~ "source_not_same_clean_base"
  end

  test "freezes configured environment before baseline and never inherits later values", %{
    source: source
  } do
    name = "REY_CODE_CHECK_FIXTURE"
    absent = "REY_CODE_CHECK_ABSENT_FIXTURE"
    previous = System.get_env(name)
    previous_absent = System.get_env(absent)
    gate = source <> "-check-gate"
    System.put_env(name, "initial")
    System.delete_env(absent)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)

      if previous_absent,
        do: System.put_env(absent, previous_absent),
        else: System.delete_env(absent)

      File.rm(gate)
    end)

    engine = engine(source, [], 0, tool_bash_env_allowlist: [name, absent])
    assert Engine.check_policy(engine).env_allowlist == [name, absent]
    Engine.subscribe(engine)
    command = "test \"$#{name}\" = initial && test -z \"$#{absent}\""
    gate_command = "while ! test -f '#{gate}'; do sleep 0.01; done; " <> command

    task =
      Task.async(fn ->
        VerifiedChange.run(options(source, commands: [gate_command, command]), engine)
      end)

    assert_receive {:projection_snapshot, _projection}, 5_000
    System.put_env(name, "changed")
    System.put_env(absent, "added")
    File.write!(gate, "release")
    assert {:ok, report} = Task.await(task, 30_000)
    retain_cleanup(report)
    assert report.outcome == :ready

    assert Enum.all?(
             report.verification["baseline"] ++ report.verification["checks"],
             &(&1["exit_code"] == 0)
           )

    refute Map.has_key?(report.verification, "environment")
    refute Map.has_key?(report.verification, "bash_policy")
  end

  test "large successful stdout and stderr retain bounded explicit previews", %{source: source} do
    engine = engine(source)
    command = "printf '%20000s' x; printf 'diagnostic' >&2"
    assert {:ok, report} = VerifiedChange.run(options(source, commands: [command]), engine)
    retain_cleanup(report)

    for evidence <- report.verification["baseline"] ++ report.verification["checks"] do
      assert evidence["exit_code"] == 0
      assert evidence["error"] == nil
      assert byte_size(evidence["output"]) <= 16_384
      assert evidence["output"] =~ "diagnostic"
      assert String.ends_with?(evidence["output"], "[check output preview truncated]")
    end
  end

  test "retains both streams for successful and failing commands", %{source: source} do
    engine = engine(source)

    for exit_code <- [0, 7] do
      command = "printf stdout; printf stderr >&2; exit #{exit_code}"
      {status, report} = VerifiedChange.run(options(source, commands: [command]), engine)
      retain_cleanup(report)
      assert status == if(exit_code == 0, do: :ok, else: :error)

      assert [%{"output" => "stdoutstderr", "exit_code" => ^exit_code, "error" => nil}] =
               report.verification["baseline"]
    end
  end

  test "capture overflow on either stream blocks before implementation", %{source: source} do
    engine = engine(source)

    for redirect <- ["", " >&2"] do
      command = "printf '%1048577s' x" <> redirect
      assert {:error, report} = VerifiedChange.run(options(source, commands: [command]), engine)
      retain_cleanup(report)
      assert report.error == "check output limit exceeded"
      assert report.turn_id == nil
      assert [%{"output" => output}] = report.verification["baseline"]
      assert byte_size(output) <= 16_384
    end
  end

  test "invalid UTF-8 on either stream blocks even with a successful exit", %{source: source} do
    engine = engine(source)

    for redirect <- ["", " >&2"] do
      command = "printf '\\377'" <> redirect
      assert {:error, report} = VerifiedChange.run(options(source, commands: [command]), engine)
      retain_cleanup(report)
      assert report.error == "check output is not UTF-8"
      assert report.turn_id == nil
    end
  end

  test "owner timeout and resource limits remain authoritative", %{source: source} do
    engine =
      engine(source, [], 0,
        tool_bash_timeout_ms: 20,
        tool_bash_cpu_seconds: 7,
        tool_bash_open_files: 64
      )

    policy = Engine.check_policy(engine)
    assert policy.cpu_seconds == 7
    assert policy.open_files == 64
    assert {:error, report} = VerifiedChange.run(options(source, commands: ["sleep 2"]), engine)
    retain_cleanup(report)
    assert report.error == "check timed out"
    assert report.turn_id == nil
  end

  test "checks execute under configured CPU and open-file limits", %{source: source} do
    engine = engine(source, [], 0, tool_bash_cpu_seconds: 7, tool_bash_open_files: 64)
    command = "test \"$(ulimit -t)\" = 7 && test \"$(ulimit -n)\" = 64"
    assert {:ok, report} = VerifiedChange.run(options(source, commands: [command]), engine)
    retain_cleanup(report)
    assert report.outcome == :ready
  end

  test "snapshots include untracked binary files without changing the caller index", %{
    source: source
  } do
    base = String.trim(git!(source, ["rev-parse", "HEAD"]))
    File.write!(Path.join(source, "binary.dat"), <<0, 1, 255, 2>>)
    index_before = git!(source, ["ls-files", "--stage"])
    assert {:ok, patch, hash} = Worktree.snapshot(source, base, deadline())
    assert patch =~ "GIT binary patch"
    assert hash == Hashing.sha256_hex(base <> "\n" <> patch)
    assert git!(source, ["ls-files", "--stage"]) == index_before
  end

  test "headless approval cancels its turn and durably blocks", %{source: source} do
    engine =
      engine(source, [%{tool: "write", arguments: %{"path" => "new.txt", "content" => "hello"}}])

    assert {:error, report} = VerifiedChange.run(options(source), engine)
    retain_cleanup(report)
    assert report.error =~ "operator_interaction_required"
    snapshot = Engine.snapshot(engine)
    assert snapshot.turns[report.turn_id].status == :terminal
    assert snapshot.turns[report.turn_id].outcome == :cancelled
    assert snapshot.sessions[report.session_id].verified_change.phase == "blocked"
  end

  test "final-check mutation blocks and retains the last immutable candidate", %{source: source} do
    engine = engine(source, [edit_call()])
    command = "if test \"$(cat value.txt)\" = after; then printf tampered > value.txt; fi"
    assert {:error, report} = VerifiedChange.run(options(source, commands: [command]), engine)
    retain_cleanup(report)
    assert report.error =~ "mutated candidate"
    assert report.turn_id != nil
    assert report.verification["patch"] =~ "+after"
    assert Enum.all?(report.verification["checks"], &(&1["error"] != nil))
    assert File.read!(Path.join(source, "value.txt")) == "before\n"
  end

  test "failing final checks exhaust repairs in the same Session with the frozen contract", %{
    source: source
  } do
    engine = engine(source, [edit_call()])
    command = "test \"$(cat value.txt)\" = before"

    assert {:error, report} =
             VerifiedChange.run(options(source, commands: [command], max_repair_count: 2), engine)

    retain_cleanup(report)
    assert report.error =~ "repair_exhausted"
    snapshot = Engine.snapshot(engine)
    session = snapshot.sessions[report.session_id]
    turns = snapshot.turns |> Map.values() |> Enum.filter(&(&1.session_id == session.id))
    assert length(turns) == 3
    assert session.verified_change.repair_count == 2

    for turn <- turns do
      message = snapshot.messages[turn.user_message_id]
      assert message.body =~ Jason.encode!(command)
      assert message.body =~ "Change before to after"
    end
  end

  test "report-only Testing stage analyzes failed checks before Main repairs", %{source: source} do
    engine = engine(source, [edit_call()])
    command = "test \"$(cat value.txt)\" = before"

    assert {:error, report} =
             VerifiedChange.run(
               options(source,
                 commands: [command],
                 max_repair_count: 1,
                 testing_provider: "simulator",
                 testing_model: "analysis-model"
               ),
               engine
             )

    retain_cleanup(report)
    assert report.error =~ "repair_exhausted"
    snapshot = Engine.snapshot(engine)
    session = snapshot.sessions[report.session_id]
    assert session.verified_change.phase == "blocked"
    assert session.verified_change.repair_count == 1

    analysis = session.verified_change.analysis
    assert %{"outcome" => "completed", "error" => nil} = analysis
    assert is_binary(analysis["response"]) and analysis["response"] != ""
    assert is_binary(analysis["turn_id"])
    assert snapshot.turns[analysis["turn_id"]].mode == :delegate

    testing = Enum.find(session.participants, &(&1.name == "Testing"))
    assert testing.kind == :task
    assert to_string(testing.provider) == "simulator"

    turns =
      snapshot.turns
      |> Map.values()
      |> Enum.filter(&(&1.session_id == session.id and &1.mode == :direct))

    assert length(turns) == 2

    assert Enum.any?(turns, fn turn ->
             snapshot.messages[turn.user_message_id].body =~
               ~s("analysis":{"outcome":"completed")
           end)

    delegate_turns =
      snapshot.turns
      |> Map.values()
      |> Enum.filter(&(&1.session_id == session.id and &1.mode == :delegate))

    assert length(delegate_turns) == 1
  end

  test "report-only Release stage drafts metadata without affecting readiness", %{source: source} do
    engine = engine(source)

    assert {:ok, report} =
             VerifiedChange.run(
               options(source,
                 commands: ["true"],
                 release_provider: "simulator",
                 release_model: "release-model"
               ),
               engine
             )

    retain_cleanup(report)
    assert report.outcome == :ready
    session = Engine.snapshot(engine).sessions[report.session_id]
    assert session.verified_change.phase == "ready"

    metadata = session.verified_change.metadata
    assert %{"outcome" => "completed", "error" => nil} = metadata
    assert is_binary(metadata["response"]) and metadata["response"] != ""
    assert is_binary(metadata["turn_id"])
    assert Engine.snapshot(engine).turns[metadata["turn_id"]].mode == :delegate
    assert File.read!(Path.join(source, "value.txt")) == "before\n"
  end

  test "unresolvable stage runtimes fail closed before any journal or check", %{source: source} do
    engine = engine(source)

    assert {:error, report} =
             VerifiedChange.run(
               options(source, testing_provider: "missing-provider", testing_model: "m"),
               engine
             )

    assert report.session_id == nil
    assert report.error =~ "unknown_provider"
  end

  test "incomplete stage runtime pairs are rejected during option validation", %{source: source} do
    assert {:error, error} =
             VerifiedChange.validate_options(options(source, testing_provider: "simulator"))

    assert error =~ "testing_provider"

    assert {:error, error} =
             VerifiedChange.validate_options(options(source, release_model: "m"))

    assert error =~ "release_provider"
    assert :ok = VerifiedChange.validate_options(options(source))
  end

  test "source changed by an owner command cannot produce ready", %{source: source} do
    engine = engine(source)
    quoted_source = "'" <> String.replace(source, "'", "'\\''") <> "'"

    assert {:error, report} =
             VerifiedChange.run(
               options(source,
                 commands: ["printf changed > #{quoted_source}/value.txt"]
               ),
               engine
             )

    retain_cleanup(report)
    assert report.error =~ "source_not_same_clean_base"
  end

  test "attributes and oversized patches fail closed", %{source: source} do
    base = String.trim(git!(source, ["rev-parse", "HEAD"]))
    File.write!(Path.join(source, ".gitattributes"), "*.txt text\n")
    assert {:error, :unsupported_git_attributes} = Worktree.snapshot(source, base, deadline())
    File.rm!(Path.join(source, ".gitattributes"))
    File.write!(Path.join(source, "large.txt"), String.duplicate("x", 2 * 1024 * 1024))
    assert {:error, {:output_limit_exceeded, _}} = Worktree.snapshot(source, base, deadline())
  end

  defp edit_call do
    %{
      tool: "edit",
      arguments: %{
        "path" => "value.txt",
        "source_hash" => Hashing.sha256_hex("before\n"),
        "patches" => [%{"old_string" => "before", "new_string" => "after"}]
      }
    }
  end

  test "operator questions cancel and block without an interactive owner", %{source: source} do
    engine =
      engine(source, [
        %{
          tool: "ask_operator",
          arguments: %{
            "question" => "Which option?",
            "options" => [%{"label" => "A"}, %{"label" => "B"}]
          }
        }
      ])

    assert {:error, report} = VerifiedChange.run(options(source), engine)
    retain_cleanup(report)
    assert report.error =~ "operator_interaction_required"
    assert Engine.snapshot(engine).turns[report.turn_id].outcome == :cancelled
  end

  test "total deadline cancels an active assistant without removing its worktree", %{
    source: source
  } do
    engine = engine(source, [], 1000)
    # A wide deadline keeps the assertion robust on a loaded machine while
    # the delayed assistant remains mid-round when it fires.
    assert {:error, report} = VerifiedChange.run(options(source, timeout_ms: 5000), engine)
    retain_cleanup(report)
    assert report.error =~ "timeout"
    assert report.turn_id != nil
    assert Engine.snapshot(engine).turns[report.turn_id].outcome == :cancelled
    assert File.dir?(report.verification["workspace"])
  end

  defp options(source, overrides \\ []) do
    Map.merge(
      %{
        prompt: "Change before to after",
        workspace: source,
        commands: ["true"],
        max_repair_count: 0,
        timeout_ms: 30_000,
        check_timeout_ms: 5_000
      },
      Map.new(overrides)
    )
  end

  defp retain_cleanup(report) do
    on_exit(fn ->
      DelegationWorktree.cleanup(%{
        workspace: report.verification["workspace"],
        source_workspace: report.verification["source_workspace"]
      })
    end)
  end

  defp engine(source, tools \\ [], delay_ms \\ 0, config_options \\ []) do
    suffix = System.unique_integer([:positive])
    registry = :"verified_registry_#{suffix}"
    events = :"verified_events_#{suffix}"
    supervisor = :"verified_supervisor_#{suffix}"
    name = :"verified_engine_#{suffix}"
    path = Path.join(System.tmp_dir!(), "verified-store-#{suffix}.sqlite3")
    store = start_supervised!({ReyCode.EventStore, name: nil, path: path})
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Registry, keys: :duplicate, name: events})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: supervisor})

    config =
      ReyCode.RuntimeConfig.fresh(
        Keyword.merge(
          [
            default_provider: :simulator,
            allow_simulator_provider: true,
            agent_delay_ms: delay_ms
          ],
          config_options
        )
      )

    start_supervised!(
      {Engine,
       name: name,
       event_store: store,
       agent_supervisor: supervisor,
       agent_registry: registry,
       event_registry: events,
       provider_catalog: ReyCode.Provider.Catalog,
       config: config,
       simulator_opts: [
         seed: 0,
         delay_ms: 0,
         jitter_ms: 0,
         failure_rate: 0.0,
         tool_requests: tools
       ]}
    )

    {:ok, _session_id} = Engine.ensure_workspace_session(source, name)
    on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1) end)
    name
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 10_000

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    output
  end
end
