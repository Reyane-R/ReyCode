defmodule ReyCode.Security.VerifiedChangeBoundaryTest do
  use ExUnit.Case, async: false

  alias ReyCode.{EventStore, Hashing, RuntimeConfig, ToolRegistry}
  alias ReyCode.Tool.Result

  alias ReyCode.Orchestration.{
    Engine,
    EventEntries,
    InvocationRequest,
    Projector,
    Session,
    VerifiedChange
  }

  alias ReyCode.Orchestration.Engine.{Client, Persistence}
  alias ReyCode.Security.{ApprovalRules, CanonicalPath, VerifiedChangeBoundary}
  alias ReyCode.Test.Wait
  alias ReyCode.Tool.Request

  @agent_registry __MODULE__.AgentRegistry
  @event_registry __MODULE__.EventRegistry
  @agent_supervisor __MODULE__.AgentSupervisor

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "reycode-boundary-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, directory} = CanonicalPath.resolve(directory)
    workspace = Path.join(directory, "worktree")
    source = Path.join(directory, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "file.txt"), "source")
    git!(source, ["init", "--quiet"])
    git!(source, ["add", "file.txt"])

    git!(source, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "-c",
      "commit.gpgSign=false",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    git!(source, ["worktree", "add", "--detach", workspace])
    File.write!(Path.join(workspace, "file.txt"), "before")
    File.mkdir_p!(Path.join(workspace, ".reycode"))

    File.write!(
      Path.join(workspace, ".reycode/approval_rules.json"),
      Jason.encode!(%{"version" => 1, "allow" => %{"bash" => ["touch escaped"]}})
    )

    config =
      RuntimeConfig.fresh(
        tool_permissions: %{
          default: :allow,
          rules: [%{tool: "write", action: :ask}, %{tool: "bash", action: :ask}]
        },
        allow_simulator_provider: true,
        default_provider: :simulator,
        workspace_roots: [directory]
      )

    %{directory: directory, workspace: workspace, source: source, config: config}
  end

  test "closed tool list and phase policy do not affect ordinary Sessions", context do
    session = session(context)
    allowed = ~w(read edit write grep glob list ask_operator update_plan)
    assert VerifiedChangeBoundary.tool_names(session) == allowed
    assert VerifiedChangeBoundary.tool_names(%Session{}) == nil

    for tool <-
          ~w(bash git process eval debug lsp memory web_search read_url artifact_read spawn_task spawn_tasks send_peer native_tool Read) do
      assert {:error, :verified_change_tool_forbidden} =
               VerifiedChangeBoundary.authorize(session, %{tool: tool, arguments: %{}})

      assert :ok = VerifiedChangeBoundary.authorize(%Session{}, %{tool: tool, arguments: %{}})
    end

    for phase <- ~w(preparing baseline verifying analyzing releasing ready blocked) do
      frozen = %{session | verified_change: %{session.verified_change | phase: phase}}
      assert VerifiedChangeBoundary.tool_names(frozen) == []

      for tool <- allowed do
        assert {:error, :verified_change_phase_forbidden} =
                 VerifiedChangeBoundary.authorize(frozen, %{tool: tool, arguments: %{}})
      end
    end
  end

  test "stage turns are coordinator-only and limited to the analyzing and releasing phases",
       context do
    {engine, _store, session_id} = start_engine(context, [])

    assert {:error, :verified_change_not_owner} =
             Engine.post_verified_stage_turn(session_id, "participant-x", "Analyze", engine)

    {:ok, turn_id} = Engine.post_message(session_id, "Implement", :direct, engine)
    assert Wait.terminal_turn(engine, turn_id)
    phase = Engine.snapshot(engine).sessions[session_id].verified_change.phase
    assert phase == "implementing"

    assert {:error, :verified_change_not_owner} =
             Engine.post_verified_stage_turn(session_id, "participant-x", "Analyze", engine)
  end

  test "registry rechecks .git aliases, case, containment and hardlinks before mutations",
       context do
    git_file = File.read!(Path.join(context.workspace, ".git"))
    File.ln_s!(".git", Path.join(context.workspace, "git-alias"))
    File.ln_s!(context.source, Path.join(context.workspace, "outside"))
    File.ln!(Path.join(context.source, "file.txt"), Path.join(context.workspace, "hard-alias"))
    File.mkdir_p!(Path.join(context.workspace, "nested/.git"))
    File.write!(Path.join(context.workspace, "nested/.git/config"), "protected")
    File.ln_s!("nested/.git", Path.join(context.workspace, "git-dir-alias"))
    File.ln!(Path.join(context.workspace, ".git"), Path.join(context.workspace, "git-hard-alias"))

    for tool <- ~w(write edit),
        path <- [
          ".git",
          ".GIT",
          ".GiT/config",
          "git-alias",
          "git-dir-alias/config",
          "git-hard-alias",
          "outside/file.txt",
          "hard-alias"
        ] do
      request = scoped_request(context, tool, mutation_arguments(path))
      assert {:error, _reason} = VerifiedChangeBoundary.validate_request(request)
      refute ToolRegistry.execute(request, context.config).ok
    end

    assert File.read!(Path.join(context.workspace, ".git")) == git_file
    assert File.read!(Path.join(context.source, "file.txt")) == "source"
  end

  test "scoped registry ignores broad request and config roots; ordinary tools stay unchanged",
       context do
    request = scoped_request(context, "read", %{"path" => Path.join(context.source, "file.txt")})
    refute ToolRegistry.execute(request, context.config).ok
    assert ToolRegistry.execute(%{request | verified_workspace: nil}, context.config).ok

    request = scoped_request(context, "edit", mutation_arguments("file.txt"))
    assert ToolRegistry.execute(request, context.config).ok
    assert File.read!(Path.join(context.workspace, "file.txt")) == "after"

    write = scoped_request(context, "write", %{"path" => "new.txt", "content" => "new"})
    assert {:ask, approved_request} = ToolRegistry.dispatch(write, context.config)
    assert approved_request.roots == [context.workspace]
    assert approved_request.workspace == context.workspace
    refute File.exists?(Path.join(context.workspace, "new.txt"))
  end

  test "provider bash allow rules and delegation requests are durably denied without children",
       context do
    calls = [
      %{tool: "bash", arguments: %{"command" => "touch escaped"}},
      %{tool: "spawn_task", arguments: %{"participant" => "worker", "brief" => "escape"}},
      %{tool: "spawn_tasks", arguments: %{}},
      %{tool: "native_tool", arguments: %{}}
    ]

    assert ApprovalRules.allows?(context.workspace, hd(calls))
    {engine, store, session_id} = start_engine(context, calls)

    assert {:ok, _participant_id} =
             Engine.add_task_participant(session_id, "worker", "work", engine)

    {:ok, turn_id} = Engine.post_message(session_id, "Try tools", :direct, engine)
    assert Wait.terminal_turn(engine, turn_id).outcome == :completed
    projection = Engine.snapshot(engine)
    assert map_size(projection.invocations) == 1
    [invocation] = Map.values(projection.invocations)
    assert map_size(invocation.tool_runs) == length(calls)
    assert Enum.all?(Map.values(invocation.tool_runs), &(&1.status == :failed))
    refute File.exists?(Path.join(context.workspace, "escaped"))
    events = EventStore.load(store)
    refute Enum.any?(events, &(&1.type in [:tool_run_started, :delegation_opened]))
    assert Projector.replay(events) == projection
  end

  test "Engine binds every workspace tool to verified worktree despite broad config and source Session",
       context do
    calls = [
      %{tool: "read", arguments: %{"path" => Path.join(context.source, "file.txt")}},
      %{tool: "edit", arguments: mutation_arguments(Path.join(context.source, "file.txt"))},
      %{tool: "write", arguments: %{"path" => ".GIT", "content" => "bad"}},
      %{tool: "read", arguments: %{"path" => "file.txt"}},
      %{tool: "edit", arguments: mutation_arguments("file.txt")},
      %{tool: "list", arguments: %{"path" => "."}},
      %{tool: "glob", arguments: %{"path" => ".", "pattern" => "*.txt"}},
      %{tool: "grep", arguments: %{"path" => ".", "pattern" => "after"}}
    ]

    {engine, _store, session_id} = start_engine(context, calls)
    {:ok, turn_id} = Engine.post_message(session_id, "Scoped work", :direct, engine)
    assert Wait.terminal_turn(engine, turn_id).outcome == :completed
    [invocation] = Map.values(Engine.snapshot(engine).invocations)
    runs = Map.values(invocation.tool_runs)
    assert Enum.count(runs, &(&1.status == :failed)) == 3
    assert Enum.all?(runs, &(&1.workspace == context.workspace))
    assert Enum.all?(runs, &(&1.workspace_roots == [context.workspace]))
    assert File.read!(Path.join(context.workspace, "file.txt")) == "after"
    assert File.read!(Path.join(context.source, "file.txt")) == "source"

    request =
      InvocationRequest.build(invocation, Engine.snapshot(engine), %{
        agent_delay_ms: 0,
        simulator_opts: []
      })

    assert request.workspace == context.workspace
    assert request.tool_names == VerifiedChangeBoundary.tool_names(session(context))
  end

  test "write waits for owner approval and approved execution uses persisted scope", context do
    {engine, store, session_id} = start_engine(context, [write_call()])
    {:ok, turn_id} = Engine.post_message(session_id, "Write", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    assert run.authorization == :ask
    refute File.exists?(Path.join(context.workspace, "new.txt"))
    refute Enum.any?(EventStore.load(store), &(&1.type == :tool_run_started))
    assert :ok = Engine.resolve_tool_run(invocation.id, run.id, :approve, engine)
    assert Wait.terminal_turn(engine, turn_id).outcome == :completed
    assert File.read!(Path.join(context.workspace, "new.txt")) == "new"
    refute File.exists?(Path.join(context.source, "new.txt"))
  end

  test "approved existing run is rechecked at start after phase closes", context do
    {engine, store, session_id} = start_engine(context, [write_call()])
    {:ok, _turn_id} = Engine.post_message(session_id, "Write", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    approve_without_admission(engine, invocation, run)
    record = Engine.snapshot(engine).sessions[session_id].verified_change
    blocked = %{record | phase: "blocked", error: "Stopped"}

    assert :ok =
             Engine.record_verified_change(session_id, VerifiedChange.to_wire(blocked), engine)

    assert {:error, {:verified_change_denied, :verified_change_phase_forbidden}} =
             Client.tool_run_started(engine, invocation.id, run.id)

    projection = Engine.snapshot(engine)
    assert projection.invocations[invocation.id].tool_runs[run.id].status == :failed
    assert Projector.replay(EventStore.load(store)) == projection
    refute File.exists?(Path.join(context.workspace, "new.txt"))
  end

  test "approved existing run is denied when path becomes a git alias before start", context do
    git_file = File.read!(Path.join(context.workspace, ".git"))
    {engine, store, session_id} = start_engine(context, [write_call()])
    {:ok, _turn_id} = Engine.post_message(session_id, "Write", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    approve_without_admission(engine, invocation, run)
    File.ln_s!(".git", Path.join(context.workspace, "new.txt"))

    assert {:error, {:verified_change_denied, :verified_change_git_path_forbidden}} =
             Client.tool_run_started(engine, invocation.id, run.id)

    assert File.read!(Path.join(context.workspace, ".git")) == git_file
    refute Enum.any?(EventStore.load(store), &(&1.type == :tool_run_started))
  end

  test "already approved ordinary bash cannot execute after Session opts into verification",
       context do
    call = %{tool: "bash", arguments: %{"command" => "touch forbidden"}}
    {engine, store, session_id} = start_engine(context, [call], :ordinary)
    {:ok, _turn_id} = Engine.post_message(session_id, "Bash", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    approve_without_admission(engine, invocation, run)
    attach_verified_change(engine, session_id, context)

    assert {:error, {:verified_change_denied, :verified_change_tool_forbidden}} =
             Client.tool_run_started(engine, invocation.id, run.id)

    refute File.exists?(Path.join(context.source, "forbidden"))
    refute Enum.any?(EventStore.load(store), &(&1.type == :tool_run_started))
  end

  test "an unencodable tool failure is refused without crashing the Engine", context do
    {engine, _store, session_id} = start_engine(context, [write_call()], :ordinary)
    {:ok, _turn_id} = Engine.post_message(session_id, "Write", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    approve_without_admission(engine, invocation, run)
    assert :ok = Client.tool_run_started(engine, invocation.id, run.id)

    raw = %{"ok" => false, "error" => {:missing_argument, :source_hash}, "metadata" => %{}}

    assert {:error, :invalid_tool_run_payload} =
             Client.tool_run_failed(engine, invocation.id, run.id, raw)

    assert Process.alive?(engine)

    wire = Result.to_wire(Result.error({:missing_argument, :source_hash}))

    assert :ok = Client.tool_run_failed(engine, invocation.id, run.id, wire)
    failed = Engine.snapshot(engine).invocations[invocation.id].tool_runs[run.id]
    assert failed.status == :failed
    assert failed.error["error"] == "missing_argument: source_hash"
  end

  test "already approved ordinary write is rebound to persisted verified worktree at start",
       context do
    {engine, _store, session_id} = start_engine(context, [write_call()], :ordinary)
    {:ok, _turn_id} = Engine.post_message(session_id, "Write", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    assert run.workspace == context.source
    assert run.workspace_roots == [context.directory]
    approve_without_admission(engine, invocation, run)
    attach_verified_change(engine, session_id, context)

    assert {:ok, request} = Client.tool_run_started(engine, invocation.id, run.id)
    assert request.workspace == context.workspace
    assert request.roots == [context.workspace]
    assert request.verified_workspace == context.workspace
    assert ToolRegistry.execute(request, context.config).ok
    assert File.read!(Path.join(context.workspace, "new.txt")) == "new"
    refute File.exists?(Path.join(context.source, "new.txt"))
  end

  test "malformed scoped tool failures are durable rather than crashing the Engine", context do
    {engine, store, session_id} = start_engine(context, [%{tool: "grep", arguments: %{}}])
    {:ok, turn_id} = Engine.post_message(session_id, "Malformed", :direct, engine)
    assert Wait.terminal_turn(engine, turn_id).outcome == :completed
    [invocation] = Map.values(Engine.snapshot(engine).invocations)
    [run] = Map.values(invocation.tool_runs)
    assert run.status == :failed
    assert run.error["error"] =~ "missing_argument"
    assert Projector.replay(EventStore.load(store)) == Engine.snapshot(engine)
  end

  test "ignored baseline output and its canonical aliases are durably denied at claim", context do
    File.write!(Path.join(context.workspace, ".gitignore"), "generated.bin\n")
    File.write!(Path.join(context.workspace, "generated.bin"), "before")
    File.ln_s!("generated.bin", Path.join(context.workspace, "alias.bin"))

    calls =
      for tool <- ~w(write edit), path <- ~w(generated.bin alias.bin) do
        %{tool: tool, arguments: mutation_arguments(path)}
      end

    {engine, store, session_id} = start_engine(context, calls)
    {:ok, turn_id} = Engine.post_message(session_id, "Try ignored output", :direct, engine)
    assert Wait.terminal_turn(engine, turn_id).outcome == :completed
    [invocation] = Map.values(Engine.snapshot(engine).invocations)

    assert Enum.all?(
             Map.values(invocation.tool_runs),
             &(&1.error["error"] == "verified_change_ignored_path_forbidden")
           )

    refute Enum.any?(EventStore.load(store), &(&1.type == :tool_run_started))
    assert File.read!(Path.join(context.workspace, "generated.bin")) == "before"
  end

  test "Git ignore and attribute controls cannot hide provider changes at any depth or through aliases",
       context do
    File.mkdir_p!(Path.join(context.workspace, "nested"))
    File.write!(Path.join(context.workspace, "nested/.gitignore"), "before")
    File.ln_s!("nested/.gitignore", Path.join(context.workspace, "ignore-alias"))

    for tool <- ~w(write edit),
        path <-
          ~w(.gitignore .GITIGNORE nested/.gitignore nested/.GitIgnore .gitattributes nested/.GITATTRIBUTES ignore-alias) do
      call = %{tool: tool, arguments: mutation_arguments(path)}

      assert {:error, :verified_change_git_path_forbidden} =
               VerifiedChangeBoundary.authorize(session(context), call)

      refute ToolRegistry.execute(scoped_request(context, tool, call.arguments), context.config).ok
    end

    refute File.exists?(Path.join(context.workspace, ".gitignore"))
    assert File.read!(Path.join(context.workspace, "nested/.gitignore")) == "before"
  end

  test "tracked files matching ignore rules remain editable and writable", context do
    File.write!(Path.join(context.workspace, ".gitignore"), "*.txt\n")
    request = scoped_request(context, "edit", mutation_arguments("file.txt"))
    assert :ok = VerifiedChangeBoundary.authorize(session(context), request)
    assert ToolRegistry.execute(request, context.config).ok
    request = scoped_request(context, "write", mutation_arguments("file.txt"))
    assert {:ask, _request} = ToolRegistry.dispatch(request, context.config)
    assert ToolRegistry.execute(request, context.config).ok
    assert File.read!(Path.join(context.workspace, "file.txt")) == "after"

    request = scoped_request(context, "write", mutation_arguments("untracked.txt"))
    refute ToolRegistry.execute(request, context.config).ok
    refute File.exists?(Path.join(context.workspace, "untracked.txt"))
  end

  test "approval and registry execution recheck files newly ignored after claim", context do
    {engine, store, session_id} = start_engine(context, [write_call()])
    {:ok, _turn_id} = Engine.post_message(session_id, "Write", :direct, engine)
    invocation = waiting(engine)
    [run] = Map.values(invocation.tool_runs)
    approve_without_admission(engine, invocation, run)
    request = scoped_request(context, "write", run.arguments)
    assert {:ok, _request} = VerifiedChangeBoundary.validate_request(request)
    File.write!(Path.join(context.workspace, ".gitignore"), "new.txt\n")

    assert {:error, {:verified_change_denied, :verified_change_ignored_path_forbidden}} =
             Client.tool_run_started(engine, invocation.id, run.id)

    refute ToolRegistry.execute(request, context.config).ok
    refute File.exists?(Path.join(context.workspace, "new.txt"))
    refute Enum.any?(EventStore.load(store), &(&1.type == :tool_run_started))
  end

  test "ignore lookup ignores foreign Git environment and never launches configured fsmonitor",
       context do
    File.write!(Path.join(context.workspace, ".gitignore"), "generated.bin\n")
    File.write!(Path.join(context.workspace, "generated.bin"), "before")
    File.write!(Path.join(context.source, "generated.bin"), "foreign")
    git!(context.source, ["add", "generated.bin"])
    marker = Path.join(context.directory, "helper-ran")
    helper = Path.join(context.directory, "fsmonitor")
    File.write!(helper, "#!/bin/sh\n/usr/bin/touch '#{marker}'\n")
    File.chmod!(helper, 0o700)
    git!(context.workspace, ["config", "core.fsmonitor", helper])

    overrides = %{
      "GIT_DIR" => Path.join(context.source, ".git"),
      "GIT_WORK_TREE" => context.source,
      "GIT_INDEX_FILE" => Path.join(context.source, ".git/index"),
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "core.fsmonitor",
      "GIT_CONFIG_VALUE_0" => helper,
      "GIT_CONFIG_GLOBAL" => Path.join(context.directory, "missing-config")
    }

    previous = Map.new(overrides, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      System.put_env(overrides)
      request = scoped_request(context, "edit", mutation_arguments("generated.bin"))

      assert {:error, :verified_change_ignored_path_forbidden} =
               VerifiedChangeBoundary.validate_request(request)

      refute ToolRegistry.execute(request, context.config).ok
      request = scoped_request(context, "edit", mutation_arguments("file.txt"))
      assert ToolRegistry.execute(request, context.config).ok
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end

    refute File.exists?(marker)
    assert File.read!(Path.join(context.workspace, "generated.bin")) == "before"
  end

  test "unavailable Git metadata fails closed without changing ordinary-session behavior",
       context do
    File.rm!(Path.join(context.workspace, ".git"))
    request = scoped_request(context, "edit", mutation_arguments("file.txt"))

    assert {:error, :verified_change_git_lookup_failed} =
             VerifiedChangeBoundary.validate_request(request)

    refute ToolRegistry.execute(request, context.config).ok
    assert File.read!(Path.join(context.workspace, "file.txt")) == "before"

    assert ToolRegistry.execute(
             %{request | verified_workspace: nil, workspace: context.workspace},
             context.config
           ).ok
  end

  defp git!(workspace, arguments) do
    assert {output, 0} =
             System.cmd("git", ["-c", "core.hooksPath=/dev/null" | arguments],
               cd: workspace,
               stderr_to_stdout: true
             )

    output
  end

  defp start_engine(context, calls, mode \\ :verified) do
    store =
      start_supervised!(
        {EventStore, name: nil, path: Path.join(context.directory, "events.sqlite3")}
      )

    start_supervised!({Registry, keys: :unique, name: @agent_registry})
    start_supervised!({Registry, keys: :duplicate, name: @event_registry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: @agent_supervisor})

    engine =
      start_supervised!(
        {Engine,
         name: __MODULE__.Engine,
         event_store: store,
         event_registry: @event_registry,
         agent_registry: @agent_registry,
         agent_supervisor: @agent_supervisor,
         config: context.config,
         agent_delay_ms: 0,
         simulator_opts: [delay_ms: 0, jitter_ms: 0, failure_rate: 0.0, tool_requests: calls]}
      )

    {:ok, session_id} = Engine.create_blank_session("Verified", context.source, engine)
    if mode == :verified, do: attach_verified_change(engine, session_id, context)
    {engine, store, session_id}
  end

  defp attach_verified_change(engine, session_id, context) do
    change = session(context).verified_change

    for phase <- ~w(preparing baseline implementing) do
      record = %{
        change
        | phase: phase,
          baseline: if(phase == "implementing", do: change.baseline, else: [])
      }

      assert :ok =
               Engine.record_verified_change(session_id, VerifiedChange.to_wire(record), engine)
    end
  end

  defp session(context) do
    %Session{
      verified_change: %VerifiedChange{
        id: "change",
        phase: "implementing",
        workspace: context.workspace,
        source_workspace: context.source,
        base_commit: "base",
        prompt: "Fix",
        commands: ["true"],
        max_repair_count: 1,
        repair_count: 0,
        timeout_ms: 60_000,
        check_timeout_ms: 10_000,
        baseline: [
          %{
            "command" => "true",
            "exit_code" => 0,
            "output" => "",
            "error" => nil,
            "snapshot_hash" => "hash"
          }
        ],
        checks: [],
        patch: "",
        patch_hash: nil,
        error: nil
      }
    }
  end

  defp scoped_request(context, tool, arguments) do
    Request.new(
      tool: tool,
      arguments: arguments,
      workspace: context.source,
      roots: [context.directory],
      verified_workspace: context.workspace
    )
  end

  defp mutation_arguments(path) do
    %{
      "path" => path,
      "content" => "after",
      "source_hash" => Hashing.sha256_hex("before"),
      "patches" => [%{"old_string" => "before", "new_string" => "after"}]
    }
  end

  defp write_call, do: %{tool: "write", arguments: %{"path" => "new.txt", "content" => "new"}}

  defp waiting(engine) do
    Wait.projection(engine, fn projection ->
      Enum.find(Map.values(projection.invocations), &(&1.status == :waiting_tool_approval))
    end)
  end

  defp approve_without_admission(engine, invocation, run) do
    await_worker_release(engine, invocation.id, 100)

    :sys.replace_state(engine, fn state ->
      Persistence.append_and_apply!(state, [
        EventEntries.tool_run_approval_resolved(invocation, run, :approve)
      ])
    end)
  end

  defp await_worker_release(_engine, _invocation_id, 0),
    do: flunk("worker did not release admission")

  defp await_worker_release(engine, invocation_id, attempts) do
    if Map.has_key?(:sys.get_state(engine).active_executions, invocation_id) do
      receive do
      after
        10 -> await_worker_release(engine, invocation_id, attempts - 1)
      end
    end
  end
end
