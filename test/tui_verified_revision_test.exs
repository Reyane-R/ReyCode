defmodule ReyCode.TUI.VerifiedRevisionTest do
  use ExUnit.Case, async: true

  alias ReyCode.{EventStore, RuntimeConfig}
  alias ReyCode.Orchestration.{DelegationWorktree, Engine}
  alias ReyCode.Security.CanonicalPath
  alias ReyCode.Test.Wait
  alias ReyCode.TUI.Verification

  @moduletag :tmp_dir
  @engine __MODULE__.Engine
  @registry __MODULE__.Registry
  @events __MODULE__.Events

  defmodule Surface do
    use Breeze.View
    @impl true
    def mount(assigns, term) do
      target = if assigns.verification.mode == :setup, do: "verify-goal", else: "prompt"
      {:ok, term |> assign(assigns) |> focus(target)}
    end

    @impl true
    def render(%{modal: nil} = assigns), do: ~H"<box>Session {@selected_session_id}</box>"
    def render(assigns), do: Verification.modal(%{term: assigns})
    @impl true
    def handle_event(event, payload, term), do: ReyCode.TUI.handle_event(event, payload, term)
    @impl true
    def handle_info(message, term), do: ReyCode.TUI.handle_info(message, term)
  end

  setup %{tmp_dir: dir} = context do
    source = Path.join(dir, "source")
    File.mkdir!(source)
    {:ok, source} = CanonicalPath.resolve(source)
    git!(source, ["init", "-q"])
    File.write!(Path.join(source, "value.txt"), "before\n")
    File.write!(Path.join(source, "revision.txt"), "v1\n")
    commit!(source)

    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({Registry, keys: :duplicate, name: @events})
    agents = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    tasks = start_supervised!(Task.Supervisor)
    store = start_supervised!({EventStore, name: nil, path: Path.join(dir, "events.sqlite3")})

    config =
      RuntimeConfig.fresh(
        tool_permissions: %{default: :allow, rules: [%{tool: "write", action: :ask}]},
        default_provider: :simulator,
        allow_simulator_provider: true,
        provider_discovery: false,
        agent_delay_ms: 0
      )

    tools =
      Map.get(context, :tools, [
        %{tool: "write", arguments: %{"path" => "value.txt", "content" => "after\n"}}
      ])

    start_supervised!(
      {Engine,
       name: @engine,
       event_store: store,
       agent_registry: @registry,
       event_registry: @events,
       agent_supervisor: agents,
       task_supervisor: tasks,
       config: config,
       simulator_opts: [
         seed: 0,
         delay_ms: 0,
         jitter_ms: 0,
         failure_rate: 0.0,
         tool_requests: tools
       ]}
    )

    {:ok, source_id} = Engine.create_blank_session("Source", source, @engine)
    [primary] = Engine.snapshot(@engine).sessions[source_id].participants
    :ok = Engine.configure_participant_tier(source_id, primary.id, :slow, @engine)
    %{source: source, source_id: source_id}
  end

  for activation <- [:mouse, :enter, :space] do
    @tag activation: activation
    test "#{activation} authorization routes through the real button and creates exactly one coordinator session",
         context do
      id = context.source_id

      term = %Breeze.Term{
        focused: "prompt",
        assigns: %{
          engine: @engine,
          projection: Engine.snapshot(@engine),
          selected_session_id: id,
          drafts: %{id => "keep my draft"},
          modal: nil,
          slash: nil,
          home: false,
          notice: nil
        }
      }

      assigns = Verification.open(term, "Change before to after").assigns

      surface =
        Breeze.Test.start!(Surface,
          size: {60, 20},
          start_opts: assigns,
          global_keybindings: ReyCode.TUI.global_keybindings()
        )

      on_exit(fn -> Breeze.Test.stop(surface) end)
      Breeze.Test.render!(surface)
      before = Engine.snapshot(@engine)
      Breeze.Test.input(surface, "Enter")
      assert Engine.snapshot(@engine) == before
      Breeze.Test.input(surface, "Tab")
      assert Breeze.Test.metadata(surface).focused == "verify-commands"
      for key <- String.graphemes("cat value.txt"), do: Breeze.Test.input(surface, key)

      if context.activation == :mouse do
        mouse_authorize(surface, "release")
        assert Engine.snapshot(@engine) == before
        mouse_authorize(surface, "press")
      else
        Breeze.Test.input(surface, "Tab")
        assert Breeze.Test.metadata(surface).focused == "verify-authorize"
        Breeze.Test.input(surface, if(context.activation == :enter, do: "Enter", else: " "))
      end

      metadata = Breeze.Test.metadata(surface)
      next_id = metadata.assigns.selected_session_id
      assert metadata.assigns.modal == nil, inspect(metadata.assigns.notice)
      assert metadata.assigns.notice == nil
      assert next_id != id
      retain_cleanup(next_id)
      assert map_size(Engine.snapshot(@engine).sessions) == map_size(before.sessions) + 1
      await_invocation(next_id, :waiting_tool_approval)
      assert map_size(Engine.snapshot(@engine).sessions) == map_size(before.sessions) + 1
      assert :ok = Engine.cancel_verified_change(next_id, @engine)
      await_stopped(next_id)
    end
  end

  test "Request Changes authorizes a fresh candidate from current source without reusing the old patch",
       context do
    id = start_change(context.source_id)
    approve(id)
    prior = await_phase(id, "ready")
    await_stopped(id)
    assert prior.patch =~ "+after"

    File.write!(Path.join(context.source, "revision.txt"), "v2\n")
    commit!(context.source)
    {:ok, newer_id} = Engine.create_blank_session("Newer source session", context.source, @engine)
    [newer_primary] = Engine.snapshot(@engine).sessions[newer_id].participants
    :ok = Engine.configure_participant_tier(newer_id, newer_primary.id, :smol, @engine)

    surface = open_review(id)
    Breeze.Test.input(surface, "a")
    Breeze.Test.input(surface, "e")
    setup = Breeze.Test.metadata(surface).assigns.verification
    assert setup.mode == :setup
    assert setup.decision == nil
    assert setup.goal == prior.prompt <> "\n\nRequested correction:\n"
    assert setup.commands == Enum.join(prior.commands, "\n")
    assert setup.return_review.decision == nil
    screen = Breeze.Test.render!(surface)
    assert screen =~ "current clean source"
    assert screen =~ "Original patch NOT reused"
    assert screen =~ "Authorize checks and start"
    assert screen =~ "Esc back"
    before = Engine.snapshot(@engine)
    Breeze.Test.input(surface, "Enter")
    assert Engine.snapshot(@engine) == before

    Breeze.Test.event(surface, "verify_goal_changed", %{
      value: setup.goal <> "Keep the public API stable."
    })

    Breeze.Test.input(surface, "Tab")
    assert Breeze.Test.metadata(surface).focused == "verify-commands"
    Breeze.Test.input(surface, "Tab")
    assert Breeze.Test.metadata(surface).focused == "verify-authorize"
    Breeze.Test.input(surface, "Enter")
    metadata = Breeze.Test.metadata(surface)
    next_id = metadata.assigns.selected_session_id
    assert metadata.assigns.modal == nil, inspect(metadata.assigns.notice)
    assert next_id != id
    assert metadata.assigns.drafts[id] == "keep my draft"
    retain_cleanup(next_id)

    await_invocation(next_id, :waiting_tool_approval)
    projection = Engine.snapshot(@engine)
    next = projection.sessions[next_id]
    assert next.verified_change.source_workspace == context.source
    assert next.participants == projection.sessions[id].participants
    assert next.verified_change.commands == prior.commands
    assert Enum.map(next.verified_change.baseline, & &1["output"]) == ["before\n", "v2\n"]
    assert File.read!(Path.join(next.workspace, "value.txt")) == "before\n"
    assert File.read!(Path.join(context.source, "value.txt")) == "before\n"
    assert projection.sessions[id].verified_change == prior
    assert projection.sessions[id].verified_change_resolution == nil
    assert :ok = Engine.cancel_verified_change(next_id, @engine)
    await_stopped(next_id)
  end

  for {key, decision, status} <- [{"a", :apply, :applied}, {"d", :discard, :discarded}] do
    @tag decision: decision, key: key, resolution_status: status
    test "real #{decision} dispatch records the exact patch and exposes Request Changes afterward",
         context do
      id = start_change(context.source_id)
      approve(id)
      prior = await_phase(id, "ready")
      await_stopped(id)
      surface = open_review(id)
      Breeze.Test.input(surface, "Enter")
      assert Engine.snapshot(@engine).sessions[id].verified_change_resolution == nil
      Breeze.Test.input(surface, context.key)
      Breeze.Test.input(surface, "Enter")

      resolution =
        Wait.projection(@engine, fn projection ->
          case projection.sessions[id].verified_change_resolution do
            %{status: status} = resolution when status == context.resolution_status -> resolution
            _ -> nil
          end
        end)

      assert resolution.change_id == prior.id
      assert resolution.patch_hash == prior.patch_hash
      assert resolution.decision == context.decision
      assert Engine.snapshot(@engine).sessions[id].verified_change == prior
      Breeze.Test.info(surface, {:projection_snapshot, Engine.snapshot(@engine)})
      assert Breeze.Test.render!(surface) =~ "e Request changes"
      Breeze.Test.input(surface, "e")
      assert Breeze.Test.metadata(surface).assigns.verification.mode == :setup
      assert Breeze.Test.metadata(surface).assigns.verification.decision == nil
    end
  end

  @tag tools: [
         %{
           tool: "ask_operator",
           arguments: %{
             "question" => "Which contract?",
             "options" => [%{"label" => "A"}, %{"label" => "B"}]
           }
         }
       ]
  test "a real operator wait is visible and cannot start Request Changes", context do
    id = start_change(context.source_id)
    invocation = await_invocation(id, :waiting_operator)
    projection = Engine.snapshot(@engine)
    assert projection.sessions[id].verified_change.phase == "implementing"
    assert Verification.summary(projection.sessions[id], projection) =~ "Needs your answer"
    surface = open_review(id)
    assert Breeze.Test.render!(surface) =~ "Needs your answer"
    Breeze.Test.input(surface, "e")
    assert Breeze.Test.metadata(surface).assigns.verification.mode == :review
    assert Breeze.Test.metadata(surface).assigns.notice.message =~ "Finish or reconcile"
    question = invocation.coordination.pending_question
    :ok = Engine.answer_question(invocation.id, question.id, hd(question.options).id, @engine)
    await_phase(id, "ready")
    await_stopped(id)
  end

  test "blocked review opens revision setup and cancellation restores its page without a decision",
       context do
    id = start_change(context.source_id)
    await_invocation(id, :waiting_tool_approval)
    :ok = Engine.cancel_verified_change(id, @engine)
    prior = await_phase(id, "blocked")
    await_stopped(id)
    surface = open_review(id)
    Breeze.Test.input(surface, "4")
    Breeze.Test.input(surface, "PageDown")
    Breeze.Test.input(surface, "d")
    review = Breeze.Test.metadata(surface).assigns.verification
    before = Engine.snapshot(@engine)
    Breeze.Test.input(surface, "e")
    assert Breeze.Test.render!(surface) =~ "Original patch NOT reused"
    Breeze.Test.input(surface, "Tab")
    Breeze.Test.input(surface, "Tab")
    Breeze.Test.input(surface, "Tab")
    assert Breeze.Test.metadata(surface).focused == "verify-goal"
    Breeze.Test.input(surface, "Escape")
    restored = Breeze.Test.metadata(surface).assigns.verification
    assert restored.tab == review.tab
    assert restored.offset == review.offset
    assert restored.decision == nil
    assert Engine.snapshot(@engine) == before
    assert Engine.snapshot(@engine).sessions[id].verified_change == prior
  end

  defp start_change(source_id) do
    {:ok, id} =
      Engine.start_verified_change(
        source_id,
        %{
          prompt: "Change before to after",
          commands: ["cat value.txt", "cat revision.txt"],
          timeout_ms: 30_000,
          check_timeout_ms: 5_000,
          max_repair_count: 0
        },
        @engine
      )

    retain_cleanup(id)
    id
  end

  defp mouse_authorize(surface, action) do
    screen = surface |> Breeze.Test.render!() |> then(&Regex.replace(~r/\e\[[0-9;]*m/, &1, ""))

    {line, y} =
      screen
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.find(fn {line, _y} -> String.contains?(line, "Authorize checks and start") end)

    {index, _length} = :binary.match(line, "Authorize checks and start")
    x = line |> binary_part(0, index) |> String.length()

    Breeze.Test.input(surface, %{
      "mouse" => %{"button" => "left", "action" => action, "x" => x, "y" => y}
    })
  end

  defp retain_cleanup(id) do
    record = Engine.snapshot(@engine).sessions[id].verified_change

    on_exit(fn ->
      DelegationWorktree.cleanup(%{
        source_workspace: record.source_workspace,
        workspace: record.workspace
      })
    end)
  end

  defp open_review(id) do
    term = %Breeze.Term{
      focused: "prompt",
      assigns: %{
        engine: @engine,
        projection: Engine.snapshot(@engine),
        selected_session_id: id,
        drafts: %{id => "keep my draft"},
        modal: nil,
        slash: nil,
        home: false,
        notice: nil
      }
    }

    assigns = Verification.review(term).assigns

    surface =
      Breeze.Test.start!(Surface,
        size: {60, 20},
        start_opts: assigns,
        global_keybindings: ReyCode.TUI.global_keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(surface) end)
    Breeze.Test.render!(surface)
    surface
  end

  defp approve(id) do
    invocation = await_invocation(id, :waiting_tool_approval)
    projection = Engine.snapshot(@engine)
    assert Verification.summary(projection.sessions[id], projection) =~ "Needs approval"
    run = Enum.find(Map.values(invocation.tool_runs), &(&1.status == :awaiting_approval))
    :ok = Engine.resolve_tool_run(invocation.id, run.id, :approve, @engine)
  end

  defp await_phase(id, phase) do
    Wait.projection(
      @engine,
      fn projection ->
        record = projection.sessions[id].verified_change
        if record.phase == phase, do: record
      end,
      15_000
    )
  end

  defp await_invocation(id, status) do
    Wait.projection(
      @engine,
      fn projection ->
        Enum.find(
          Map.values(projection.invocations),
          &(&1.session_id == id and &1.status == status)
        )
      end,
      15_000
    )
  end

  defp await_stopped(id), do: await_stopped(id, System.monotonic_time(:millisecond) + 5_000)

  defp await_stopped(id, deadline_ms) do
    if Engine.verified_change_status(id, @engine) != :stopped do
      assert System.monotonic_time(:millisecond) < deadline_ms

      receive do
        {:projection_snapshot, _projection} -> await_stopped(id, deadline_ms)
      after
        10 -> await_stopped(id, deadline_ms)
      end
    end
  end

  defp commit!(source) do
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
  end

  defp git!(source, args) do
    {output, 0} = System.cmd("git", args, cd: source, stderr_to_stdout: true)
    output
  end
end
