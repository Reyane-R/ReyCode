defmodule ReyCode.TUI.Verification do
  @moduledoc "Guided host-check authorization and hash-bound retained change inspection."

  use Breeze.Component
  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Validation}
  alias ReyCode.TUI.{Action, Notice, State}

  @tabs [:summary, :files, :patch, :checks]
  @fields ["verify-goal", "verify-commands", "verify-authorize"]
  @unavailable_message "Engine response unavailable; request may have been recorded. Inspect durable status; do not retry blindly."

  @spec open(map(), String.t() | nil) :: map()
  def open(term, goal \\ nil) do
    draft = Map.get(term.assigns.drafts, term.assigns.selected_session_id, "")
    goal = goal || if(String.starts_with?(draft, "/"), do: "", else: draft)

    term
    |> Component.assign(
      modal: :verification,
      slash: nil,
      notice: nil,
      verification: %{
        mode: :setup,
        response_uncertain?: false,
        goal: goal,
        commands: "",
        return_review: nil,
        return_focus: term.focused,
        clear_draft?: goal == draft or String.starts_with?(draft, "/verify"),
        decision: nil
      }
    )
    |> View.focus("verify-goal")
  end

  @spec review(map()) :: map()
  def review(term) do
    session = session(term.assigns)

    case session.verified_change do
      nil ->
        feedback(term, :info, "No verified change in this session. Use /verify to set one up.")

      change ->
        Component.assign(term,
          modal: :verification,
          slash: nil,
          notice: nil,
          verification: %{
            mode: :review,
            response_uncertain?: false,
            tab: :summary,
            offset: 0,
            decision: nil,
            change_id: change.id,
            patch_hash: change.patch_hash,
            return_focus: term.focused
          }
        )
    end
  end

  @spec focus(map()) :: map()
  def focus(%{assigns: %{verification: %{mode: :setup}}} = term) do
    index = Enum.find_index(@fields, &(&1 == term.focused)) || 0
    View.focus(term, Enum.at(@fields, rem(index + 1, length(@fields))))
  end

  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{verification: %{response_uncertain?: true}}} = term),
    do: response_unavailable(term)

  def submit(%{assigns: %{verification: %{mode: :setup}}, focused: "verify-authorize"} = term),
    do: start(term)

  def submit(%{assigns: %{verification: %{mode: :setup}}} = term),
    do: {:noreply, feedback(term, :info, "Select Authorize checks and start explicitly.")}

  def submit(%{assigns: %{verification: %{decision: nil}}} = term),
    do: {:noreply, feedback(term, :info, "Select an action first. Enter alone changes nothing.")}

  def submit(term), do: resolve(term)

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input("Enter", term), do: submit(term)

  def handle_input(key, %{assigns: %{verification: %{response_uncertain?: true}}} = term)
      when key in ["a", "d", "r", "e"],
      do: response_unavailable(term)

  def handle_input(_key, %{assigns: %{verification: %{mode: :setup}}} = term),
    do: {:noreply, term}

  def handle_input("e", term) do
    session = session(term.assigns)

    if revision_allowed?(session) do
      review = %{term.assigns.verification | decision: nil}
      change = session.verified_change

      next =
        term
        |> open(change.prompt <> "\n\nRequested correction:\n")
        |> put_review(
          commands: Enum.join(change.commands, "\n"),
          return_review: review,
          return_focus: review.return_focus,
          clear_draft?: false
        )

      {:noreply, next}
    else
      {:noreply,
       feedback(term, :warning, "Finish or reconcile current work before requesting changes.")}
    end
  end

  def handle_input(key, term) when key in ["1", "2", "3", "4"] do
    tab = Enum.at(@tabs, String.to_integer(key) - 1)
    {:noreply, put_review(term, tab: tab, offset: 0)}
  end

  def handle_input(key, term) when key in ["a", "d", "r"] do
    decision = %{"a" => :apply, "d" => :discard, "r" => :reconcile}[key]

    if decision in actions(session(term.assigns)),
      do: {:noreply, put_review(term, decision: decision)},
      else:
        {:noreply, feedback(term, :warning, "That action is not available for this evidence.")}
  end

  def handle_input(key, term) when key in ["ArrowDown", "ArrowUp", "PageDown", "PageUp"] do
    step = if key in ["PageDown", "PageUp"], do: page_size(term.assigns), else: 1
    delta = if key in ["ArrowUp", "PageUp"], do: -step, else: step
    last = max(length(lines(term.assigns)) - 1, 0)
    offset = (term.assigns.verification.offset + delta) |> max(0) |> min(last)
    {:noreply, put_review(term, offset: offset)}
  end

  def handle_input(key, term) when key in ["n", "p", "]", "["] do
    prefix = if key in ["n", "p"], do: "diff --git ", else: "@@"
    forward? = key in ["n", "]"]
    review = %{term.assigns.verification | tab: :patch}
    assigns = Map.put(term.assigns, :verification, review)

    candidates =
      assigns
      |> lines()
      |> Enum.with_index()
      |> Enum.filter(fn {line, index} ->
        String.starts_with?(line, prefix) and
          if(forward?, do: index > review.offset, else: index < review.offset)
      end)

    target = if forward?, do: List.first(candidates), else: List.last(candidates)
    offset = if target, do: elem(target, 1), else: review.offset
    {:noreply, put_review(term, tab: :patch, offset: offset)}
  end

  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("verify_goal_changed", %{value: value}, term),
    do: edit(term, :goal, value, Validation.message_max_bytes())

  def handle_event("verify_commands_changed", %{value: value}, term),
    do: edit(term, :commands, value, 8 * 4097)

  def handle_event(
        "verify_authorize",
        _payload,
        %{assigns: %{verification: %{mode: :setup}}} = term
      ),
      do: start(term)

  def handle_event(_event, _payload, _term), do: :unhandled

  @doc "Persistent projection-derived status; readiness never implies source integration."
  @spec summary(map(), map()) :: String.t()
  def summary(%{verified_change: nil}, _projection), do: ""

  def summary(session, projection) do
    change = session.verified_change

    "#{status(session, projection)} | baseline #{passed(change.baseline)}/#{length(change.commands)}" <>
      " current #{passed(change.checks)}/#{length(change.commands)} | repairs #{change.repair_count}/#{change.max_repair_count}"
  end

  @spec source_label(map()) :: String.t()
  def source_label(%{verified_change_resolution: %{status: :applied}}),
    do: "Applied; isolated checks, not rerun after integration."

  def source_label(%{verified_change_resolution: %{status: :requested}}),
    do: "Resolution requested; completion not yet confirmed."

  def source_label(%{verified_change_resolution: %{status: :indeterminate}}),
    do: "Source application uncertain. Reconcile; do not retry."

  def source_label(%{verified_change: %{phase: "blocked"}, verified_change_resolution: nil}),
    do: "Blocked; host work may still be stopping."

  def source_label(_session), do: "Source not applied by ReyCode."

  attr :term, :map, required: true

  def modal(%{term: %{verification: %{mode: :setup}}} = assigns) do
    revision? = not is_nil(assigns.term.verification.return_review)
    goal_height = if revision?, do: 5, else: 3

    goal_height =
      if assigns.term.verification.response_uncertain?,
        do: max(goal_height - 1, 3),
        else: goal_height

    reserved_rows = if assigns.term.verification.response_uncertain?, do: 13, else: 12

    commands_height =
      min(5, max(assigns.term.breeze.terminal.height - goal_height - reserved_rows, 3))

    assigns =
      Map.merge(assigns, %{
        revision?: revision?,
        goal_height: goal_height,
        commands_height: commands_height
      })

    ~H"""
    <box class="w-screen h-screen bg px-2 pt-1 overflow-hidden">
      <box class="font-bold text-primary">Verify a change</box>
      <box class="text-warning">HOST execution in a Git worktree, NOT a sandbox.</box>
      <box class="text-warning">Checks can access host files, network and credentials.</box>
      <box class="text-muted">10 min total; 2 min/check; 1 repair. No auto-apply.</box>
      <box :if={@revision?} class="text-warning">
        New candidate from current clean source; same Primary.
      </box>
      <box :if={@revision?} class="text-warning">
        Original patch NOT reused; prior evidence stays intact.
      </box>
      <box>Goal</box>
      <.textarea
        id="verify-goal"
        textarea-value={@term.verification.goal}
        textarea-submit-on-enter={false}
        br-change="verify_goal_changed"
        class={"w-full h-#{@goal_height} border focus:border-primary"}
      />
      <box>Checks in order: 1-8 lines, up to 4096 bytes each</box>
      <.textarea
        id="verify-commands"
        textarea-value={@term.verification.commands}
        textarea-submit-on-enter={false}
        br-change="verify_commands_changed"
        class={"w-full h-#{@commands_height} border focus:border-primary"}
      />
      <box
        id="verify-authorize"
        implicit={Action}
        focusable
        br-change="verify_authorize"
        class="font-bold text-warning focus:bg-warning focus:text-bg"
      >
        {if @term.verification.response_uncertain? do
          "Submission locked; close/reopen to inspect status"
        else
          "Authorize checks and start"
        end}
      </box>
      <box class="text-muted">Tab field/action; Enter authorizes on action; Esc back.</box>
      <.feedback_notice term={@term}/>
    </box>
    """
  end

  def modal(assigns) do
    rows = lines(assigns.term)
    offset = min(assigns.term.verification.offset, max(length(rows) - 1, 0))

    assigns =
      Map.merge(assigns, %{
        session: session(assigns.term),
        rows: Enum.slice(rows, offset, page_size(assigns.term)),
        position:
          "#{offset + 1}-#{min(offset + page_size(assigns.term), length(rows))}/#{length(rows)}"
      })

    ~H"""
    <box class="w-screen h-screen bg px-2 pt-1 overflow-hidden">
      <box class="font-bold text-primary">
        Verified change: {if @term.verification.response_uncertain? do
          "response unavailable"
        else
          status(@session, @term.projection)
        end}
      </box>
      <box class="text-warning">
        {if @term.verification.response_uncertain? do
          "Displayed evidence is historical; status unconfirmed."
        else
          source_label(@session)
        end}
      </box>
      <box class="text-muted">1 Summary | 2 Files | 3 Patch | 4 Checks</box>
      <box class="text-secondary">{@term.verification.tab} | rows {@position}</box>
      <box :for={line <- @rows} class="w-full">{line}</box>
      <box class="text-warning">
        {if @term.verification.response_uncertain? do
          "Submission locked; close/reopen to inspect status"
        else
          action_label(@session)
        end}
      </box>
      <box
        :if={revision_allowed?(@session) and not @term.verification.response_uncertain?}
        class="text-primary"
      >
        e Request changes (new candidate; opens setup)
      </box>
      <box class="text-muted">Selected: {@term.verification.decision || "none"}; Enter confirms.</box>
      <box class="text-muted">PgUp/PgDn page; arrows; n/p file; ]/[ hunk; Esc back</box>
      <.feedback_notice term={@term}/>
    </box>
    """
  end

  defp feedback_notice(assigns) do
    ~H"""
    <box :if={@term.verification.response_uncertain?} class="text-warning">
      <box>Engine response unavailable; request may have been</box>
      <box>recorded. Inspect durable status; do not retry blindly.</box>
    </box>
    <box
      :if={not is_nil(@term.notice) and not @term.verification.response_uncertain?}
      class={Notice.text_class(@term.notice)}
    >
      {@term.notice.message}
    </box>
    """
  end

  defp start(%{assigns: %{verification: %{response_uncertain?: true}}} = term),
    do: response_unavailable(term)

  defp start(term) do
    setup = term.assigns.verification
    commands = setup.commands |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    options = %{
      prompt: String.trim(setup.goal),
      commands: commands,
      timeout_ms: 600_000,
      check_timeout_ms: 120_000,
      max_repair_count: 1
    }

    if options.prompt != "" and length(commands) in 1..8 and
         Enum.all?(commands, &(byte_size(&1) in 1..4096)) do
      result =
        request_snapshot(term.assigns.engine, fn ->
          Engine.start_verified_change(
            term.assigns.selected_session_id,
            options,
            term.assigns.engine
          )
        end)

      case result do
        {:ok, session_id, projection} ->
          term = clear_submitted_draft(term)

          next =
            term
            |> dismiss()
            |> State.projection_updated(projection)
            |> State.select_session(session_id)
            |> View.focus("prompt")

          {:noreply, next}

        {:error, reason} ->
          {:noreply, feedback(term, :error, "Could not start verification: #{inspect(reason)}")}

        :response_unavailable ->
          response_unavailable(term)
      end
    else
      {:noreply,
       feedback(term, :warning, "Enter a goal and 1-8 nonempty checks, at most 4096 bytes each.")}
    end
  end

  defp clear_submitted_draft(%{assigns: %{verification: %{clear_draft?: true}}} = term),
    do: State.assign_draft(term, "")

  defp clear_submitted_draft(term), do: term

  defp resolve(term) do
    review = term.assigns.verification
    session = session(term.assigns)
    change = session.verified_change

    if change.id == review.change_id and change.patch_hash == review.patch_hash and
         review.decision in actions(session) do
      result =
        request_snapshot(term.assigns.engine, fn ->
          request_resolution(session.id, review, term.assigns.engine)
        end)

      case result do
        {:ok, _resolution_id, projection} ->
          next =
            term
            |> State.projection_updated(projection)
            |> put_review(decision: nil)

          {:noreply, feedback(next, :info, "Resolution recorded. See durable status above.")}

        {:error, reason} ->
          {:noreply, feedback(term, :error, "Resolution failed: #{inspect(reason)}")}

        :response_unavailable ->
          response_unavailable(term)
      end
    else
      {:noreply,
       term
       |> put_review(decision: nil)
       |> feedback(:warning, "Evidence or eligibility changed. Reopen /changes before deciding.")}
    end
  end

  defp request_resolution(session_id, %{decision: :reconcile} = review, engine),
    do: Engine.reconcile_verified_change(session_id, review.change_id, review.patch_hash, engine)

  defp request_resolution(session_id, review, engine),
    do:
      Engine.resolve_verified_change(
        session_id,
        review.change_id,
        review.patch_hash,
        review.decision,
        engine
      )

  # A lost receipt or snapshot cannot prove that the queued mutation did not commit.
  defp request_snapshot(engine, request) do
    with {:ok, id} <- request.() do
      {:ok, id, Engine.snapshot(engine)}
    end
  catch
    :exit, _reason -> :response_unavailable
  end

  defp response_unavailable(term) do
    {:noreply,
     term
     |> put_review(response_uncertain?: true, decision: nil)
     |> feedback(:warning, @unavailable_message)}
  end

  defp edit(term, field, value, max_bytes) do
    if byte_size(value) <= max_bytes do
      {:noreply, put_review(term, [{field, value}])}
    else
      {:noreply,
       feedback(term, :warning, "Input exceeds #{max_bytes} bytes; edit was not accepted.")}
    end
  end

  defp close(%{assigns: %{verification: %{return_review: review}}} = term)
       when not is_nil(review) do
    uncertain? = term.assigns.verification.response_uncertain?
    review = %{review | response_uncertain?: uncertain?, decision: nil}

    term
    |> Component.assign(
      verification: review,
      notice: if(uncertain?, do: term.assigns.notice, else: nil)
    )
    |> View.focus(review.return_focus)
  end

  defp close(term), do: dismiss(term)

  defp dismiss(term) do
    return_focus = term.assigns.verification.return_focus

    term
    |> Component.assign(modal: nil, verification: nil, notice: nil)
    |> View.focus(return_focus || "prompt")
  end

  defp put_review(term, fields),
    do:
      Component.assign(term,
        verification: Enum.into(fields, term.assigns.verification),
        notice:
          if(term.assigns.verification.response_uncertain?, do: term.assigns.notice, else: nil)
      )

  defp feedback(term, severity, message),
    do: Component.assign(term, notice: Notice.new(severity, message))

  defp session(assigns), do: Map.fetch!(assigns.projection.sessions, assigns.selected_session_id)
  defp passed(checks), do: Enum.count(checks, &(&1["exit_code"] == 0 and is_nil(&1["error"])))

  defp status(%{verified_change_resolution: %{status: status}}, _projection),
    do: status |> Atom.to_string() |> String.capitalize()

  defp status(%{verified_change: %{phase: phase}}, _projection)
       when phase in ["ready", "blocked"],
       do: String.capitalize(phase)

  defp status(session, projection) do
    turn = Map.get(projection.turns, session.active_turn_id)
    invocation_ids = if turn, do: turn.invocation_order, else: []
    statuses = Enum.map(invocation_ids, &Map.fetch!(projection.invocations, &1).status)

    cond do
      :waiting_operator in statuses -> "Needs your answer"
      :waiting_tool_approval in statuses -> "Needs approval"
      true -> String.capitalize(session.verified_change.phase)
    end
  end

  defp revision_allowed?(%{
         verified_change: %{phase: phase},
         verified_change_resolution: resolution,
         active_turn_id: nil,
         queued_turn_ids: []
       })
       when phase in ["ready", "blocked"],
       do: is_nil(resolution) or resolution.status in [:applied, :discarded, :failed]

  defp revision_allowed?(_session), do: false

  defp actions(%{verified_change_resolution: %{status: :indeterminate}}), do: [:reconcile]
  defp actions(%{verified_change_resolution: resolution}) when not is_nil(resolution), do: []
  defp actions(%{verified_change: %{phase: "ready"}}), do: [:apply, :discard]
  defp actions(%{verified_change: %{phase: "blocked"}}), do: [:discard]
  defp actions(_session), do: []

  defp action_label(session) do
    case actions(session) do
      [:apply, :discard] -> "a Apply to source | d Discard (retain evidence)"
      [:discard] -> "d select Discard (evidence and worktree retained)"
      [:reconcile] -> "r select Reconcile (read-only). Never blindly retry Apply."
      [] -> "No resolution action. /cancel stops active verification."
    end
  end

  defp page_size(assigns), do: min(24, max(assigns.breeze.terminal.height - 12, 1))

  defp lines(assigns) do
    session = session(assigns)
    change = session.verified_change
    width = max(assigns.breeze.terminal.width - 4, 8)

    text =
      case assigns.verification.tab do
        :summary ->
          Enum.join(
            [
              summary(session, assigns.projection),
              if(assigns.verification.response_uncertain?,
                do: "Source status unconfirmed; inspect durable status.",
                else: source_label(session)
              ),
              "Goal: #{change.prompt}",
              "Source workspace: #{change.source_workspace}",
              "Isolated workspace: #{change.workspace}",
              "Base: #{change.base_commit || "not captured"}",
              "Patch hash: #{change.patch_hash || "not captured"}",
              "Total limit: #{change.timeout_ms} ms; check limit: #{change.check_timeout_ms} ms",
              "Ready means checks passed on the isolated candidate, not acceptance or integration testing.",
              "Error: #{change.error || "none"}",
              resolution_error(session),
              revision_guidance(session)
            ],
            "\n"
          )

        :files ->
          change.patch
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "diff --git "))
          |> Enum.join("\n")

        :patch ->
          change.patch

        :checks ->
          "AUTHORIZED COMMANDS (in order)\n" <>
            Enum.join(change.commands, "\n") <>
            "\nBASELINE\n" <>
            check_text(change.baseline) <> "\nCURRENT CANDIDATE\n" <> check_text(change.checks)
      end

    text
    |> String.split("\n", trim: false)
    |> Enum.flat_map(fn
      "" -> [" "]
      line -> line |> String.graphemes() |> Enum.chunk_every(width) |> Enum.map(&Enum.join/1)
    end)
  end

  defp revision_guidance(session) do
    if revision_allowed?(session),
      do:
        "e Request changes: edit the original goal and checks in setup. Explicit authorization starts a fresh candidate from current clean source with the same Primary. The old patch is not reused or changed.",
      else:
        "Request changes is available after work finishes and any uncertain resolution is reconciled."
  end

  defp resolution_error(%{verified_change_resolution: %{error: error}}),
    do: "Resolution error: #{error || "none"}"

  defp resolution_error(_session), do: "No owner resolution recorded."

  defp check_text(checks) do
    Enum.map_join(checks, "\n", fn check ->
      "$ #{check["command"]}\nExit: #{inspect(check["exit_code"])}; error: #{check["error"] || "none"}\n" <>
        "Snapshot: #{check["snapshot_hash"]}\n#{check["output"]}"
    end)
  end
end
