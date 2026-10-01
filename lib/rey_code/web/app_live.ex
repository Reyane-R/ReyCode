defmodule ReyCode.Web.AppLive do
  @moduledoc """
  ReyCode Desktop: sessions sidebar, the selected conversation, owner
  actions, and delegated workers, all live from Engine broadcasts.

  Owner actions go through the same Engine calls the TUI uses: start a
  conversation, post a message, stop the active Turn, approve or deny a tool
  request, answer an OperatorQuestion, and apply or discard an isolated
  worker patch. The view never writes events itself.
  """

  use Phoenix.LiveView

  alias Phoenix.LiveView.JS
  alias ReyCode.Orchestration.{Engine, Projection}
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.TUI.Activity
  alias ReyCode.Web.Markdown

  @sessions_max_count 100
  @messages_max_count 200
  @workers_max_count 24
  @tools_per_message_max_count 8
  @report_max_bytes 4_096
  @arguments_max_bytes 4_096
  @title_max_graphemes 60

  @impl true
  def mount(_params, _session, socket) do
    projection = if connected?(socket), do: Engine.subscribe(), else: Engine.snapshot()

    {:ok,
     socket
     |> assign(id: nil, notice: nil, html_cache: %{}, projection: projection)
     |> assign(sequence: projection.sequence)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, id: params["id"], notice: nil)
    {:noreply, assign_view(socket, socket.assigns.projection)}
  end

  @impl true
  def handle_info({:projection_snapshot, projection}, socket) do
    if projection.sequence > socket.assigns.sequence,
      do: {:noreply, assign_view(socket, projection)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("start", %{"body" => body, "workspace" => workspace}, socket) do
    with false <- String.trim(body) == "",
         source when is_binary(source) <-
           Projection.newest_session_id_for_workspace(socket.assigns.projection, workspace),
         {:ok, session_id} <- Engine.create_session(source, title(body)),
         {:ok, _turn_id} <- Engine.post_message(session_id, body, :direct) do
      {:noreply, push_patch(socket, to: "/sessions/#{session_id}")}
    else
      true -> {:noreply, socket}
      nil -> {:noreply, notice(socket, "Choose a workspace you have used before.")}
      {:error, reason} -> {:noreply, notice(socket, "Could not start: #{format(reason)}")}
    end
  end

  def handle_event("send", %{"body" => body}, socket) do
    if String.trim(body) == "" do
      {:noreply, socket}
    else
      case Engine.post_message(socket.assigns.id, body, :direct) do
        {:ok, _turn_id} ->
          {:noreply, socket |> assign(notice: nil) |> push_event("composer:clear", %{})}

        {:error, reason} ->
          {:noreply, notice(socket, "Could not send: #{format(reason)}")}
      end
    end
  end

  def handle_event("stop", _params, socket) do
    case socket.assigns.session && socket.assigns.session.active_turn_id do
      nil -> {:noreply, socket}
      turn_id -> reply(socket, Engine.cancel_turn(turn_id, "Cancelled by user"), "stop")
    end
  end

  def handle_event("retry", _params, socket) do
    case socket.assigns.retry_turn_id do
      nil -> {:noreply, socket}
      turn_id -> reply(socket, Engine.retry_turn(turn_id), "try again")
    end
  end

  def handle_event("tool", %{"invocation" => id, "run" => run_id, "decision" => decision}, socket)
      when decision in ["approve", "deny"] do
    reply(socket, Engine.resolve_tool_run(id, run_id, decision_atom(decision)), decision)
  end

  def handle_event("merge", %{"invocation" => id, "decision" => decision}, socket)
      when decision in ["apply", "discard"] do
    reply(socket, Engine.resolve_merge(id, decision_atom(decision)), decision)
  end

  def handle_event("answer", %{"invocation" => id, "request" => request_id} = params, socket) do
    case socket.assigns.question do
      %{invocation_id: ^id, request: %{id: ^request_id} = request} ->
        answers = Enum.map(request.questions, &answer(&1, params))
        reply(socket, Engine.answer_question(id, request_id, %{answers: answers}), "answer")

      _stale ->
        {:noreply, notice(socket, "That question was already answered.")}
    end
  end

  defp reply(socket, :ok, _action), do: {:noreply, assign(socket, notice: nil)}

  defp reply(socket, {:error, reason}, action),
    do: {:noreply, notice(socket, "Could not #{action}: #{format(reason)}")}

  defp decision_atom("approve"), do: :approve
  defp decision_atom("deny"), do: :deny
  defp decision_atom("apply"), do: :apply
  defp decision_atom("discard"), do: :discard

  defp answer(item, params) do
    option_ids =
      case Map.get(params, "q-" <> item.id) do
        ids when is_list(ids) -> ids
        id when is_binary(id) -> [id]
        nil -> []
      end

    other =
      case String.trim(Map.get(params, "other-" <> item.id, "")) do
        "" -> nil
        text -> text
      end

    %{question_id: item.id, option_ids: option_ids, other: other}
  end

  defp notice(socket, text), do: assign(socket, notice: text)

  defp format(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format(reason), do: inspect(reason)

  # Same title rule as the TUI: the first words of the opening message.
  defp title(body) do
    title = body |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")

    if String.length(title) > @title_max_graphemes,
      do: String.slice(title, 0, @title_max_graphemes) <> "…",
      else: title
  end

  ## Projection → view

  defp assign_view(socket, projection) do
    now = DateTime.utc_now()
    session = socket.assigns.id && Map.get(projection.sessions, socket.assigns.id)
    sessions = recent_sessions(projection)
    {messages, cache} = messages(projection, session, socket.assigns.html_cache, now)

    assign(socket,
      projection: projection,
      sequence: projection.sequence,
      groups: groups(projection, sessions, now),
      workspaces: sessions |> Enum.map(& &1.workspace) |> Enum.uniq(),
      session: session,
      messages: messages,
      html_cache: cache,
      workers: workers(projection, session),
      tool_request: tool_request(projection, session),
      retry_turn_id: retry_turn_id(projection, session),
      question: session && question(projection, session.id)
    )
  end

  defp recent_sessions(projection) do
    projection.session_order
    |> Enum.reverse()
    |> Enum.take(@sessions_max_count)
    |> Enum.map(&Map.fetch!(projection.sessions, &1))
  end

  # Sessions grouped by workspace, groups ordered by their newest session.
  defp groups(projection, sessions, now) do
    sessions
    |> Enum.with_index()
    |> Enum.group_by(fn {session, _index} -> session.workspace end)
    |> Enum.sort_by(fn {_workspace, [{_newest, index} | _older]} -> index end)
    |> Enum.map(fn {workspace, members} ->
      items =
        Enum.map(members, fn {session, _index} -> session_item(projection, session, now) end)

      %{workspace: workspace, name: Path.basename(workspace || "Workspace"), sessions: items}
    end)
  end

  defp session_item(projection, session, now) do
    last_at =
      case session.message_order do
        [newest | _older] -> projection.messages[newest] && projection.messages[newest].created_at
        [] -> session.created_at
      end

    %{
      id: session.id,
      title: session.title || "Untitled conversation",
      working?: session.active_turn_id != nil,
      ago: ago(last_at, now)
    }
  end

  # message_order is newest first; the conversation reads oldest to newest.
  defp messages(_projection, nil, cache, _now), do: {[], cache}

  defp messages(projection, session, cache, now) do
    delegated =
      projection |> Projection.delegated_invocations(session.id) |> MapSet.new(& &1.message_id)

    messages =
      session.message_order
      |> Enum.take(@messages_max_count)
      |> Enum.reverse()
      |> Enum.reject(&MapSet.member?(delegated, &1))
      |> Enum.map(&Map.fetch!(projection.messages, &1))

    Enum.map_reduce(messages, %{}, fn message, next_cache ->
      html = cached_html(cache, message)
      item = message_item(projection, session, message, html, now)
      {item, Map.put(next_cache, message.id, {message.body, html})}
    end)
  end

  # Bodies only grow while streaming, so re-render only when the text changed.
  defp cached_html(cache, message) do
    case Map.get(cache, message.id) do
      {body, html} when body == message.body -> html
      _changed -> Markdown.to_html(message.body || "")
    end
  end

  defp message_item(projection, session, message, html, now) do
    invocation = message.invocation_id && projection.invocations[message.invocation_id]
    user? = match?(%{kind: :user}, message.author)

    %{
      id: message.id,
      user?: user?,
      name: author_name(message),
      html: html,
      streaming?: message.status == :streaming,
      failed?: message.status == :failed,
      error: message.error && Map.get(message.error, :message),
      tools: if(user?, do: {[], 0}, else: tools(invocation, session.workspace, now))
    }
  end

  defp tools(nil, _workspace, _now), do: {[], 0}

  defp tools(invocation, workspace, now) do
    runs =
      invocation.tool_run_order
      |> Enum.map(&Map.get(invocation.tool_runs, &1))
      |> Enum.reject(&is_nil/1)

    hidden = max(length(runs) - @tools_per_message_max_count, 0)
    now_ms = DateTime.to_unix(now, :millisecond)

    shown =
      runs
      |> Enum.drop(hidden)
      |> Enum.map(fn run ->
        item = Activity.tool(run, workspace || "", now_ms)
        %{id: run.id, label: item.label, target: item.target, state: tool_state(item, run)}
      end)

    {shown, hidden}
  end

  defp tool_state(_item, %{status: status}) when status in [:failed, :denied], do: "failed"
  defp tool_state(%{active?: true}, _run), do: "active"
  defp tool_state(_item, _run), do: "done"

  defp workers(_projection, nil), do: []

  defp workers(projection, session) do
    projection
    |> Projection.delegated_invocations(session.id)
    |> Enum.take(@workers_max_count)
    |> Enum.map(&worker(&1, Map.get(projection.messages, &1.message_id)))
  end

  defp worker(invocation, message) do
    %{
      id: invocation.id,
      name: invocation.participant.name,
      model: invocation.participant.model,
      status: invocation.status,
      tool_count: length(invocation.tool_run_order),
      report: report(message),
      diff: pending_diff(invocation.pending_tool_review)
    }
  end

  defp report(%{body: body}) when is_binary(body) and body != "",
    do: bounded(body, @report_max_bytes)

  defp report(_message), do: nil

  # The diff lives in the projection only while the merge waits for an Apply/Discard decision.
  defp pending_diff(%{tool: "merge", arguments: %{"diff" => diff}}) when is_binary(diff),
    do: String.split(diff, "\n")

  defp pending_diff(_review), do: nil

  defp tool_request(_projection, nil), do: nil

  defp tool_request(projection, session) do
    case Projection.pending_tool_invocation(projection, session.active_turn_id) do
      nil ->
        nil

      invocation ->
        review = invocation.pending_tool_review

        %{
          invocation_id: invocation.id,
          run_id: review.request_id,
          agent: invocation.participant.name,
          tool: review.tool,
          arguments: bounded(Jason.encode!(review.arguments, pretty: true), @arguments_max_bytes)
        }
    end
  end

  # Only the newest Turn can be retried, and only once nothing else is running.
  defp retry_turn_id(_projection, nil), do: nil
  defp retry_turn_id(_projection, %{active_turn_id: active}) when active != nil, do: nil
  defp retry_turn_id(_projection, %{message_order: []}), do: nil

  defp retry_turn_id(projection, %{message_order: [newest | _older]}) do
    with %{turn_id: turn_id} when is_binary(turn_id) <- projection.messages[newest],
         %{outcome: :failed} <- projection.turns[turn_id] do
      turn_id
    else
      _not_failed -> nil
    end
  end

  defp question(projection, session_id) do
    case Projection.pending_question_invocation(projection, session_id) do
      nil ->
        nil

      invocation ->
        %{invocation_id: invocation.id, request: invocation.coordination.pending_question}
    end
  end

  defp bounded(text, max_bytes) do
    if byte_size(text) > max_bytes,
      do: TextBuffer.truncate_utf8(text, max_bytes) <> "\n…",
      else: text
  end

  defp ago(iso, now) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> ago_seconds(DateTime.diff(now, at))
      {:error, _reason} -> ""
    end
  end

  defp ago(_value, _now), do: ""

  defp ago_seconds(seconds) when seconds < 60, do: "now"
  defp ago_seconds(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp ago_seconds(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)}h"
  defp ago_seconds(seconds) when seconds < 604_800, do: "#{div(seconds, 86_400)}d"
  defp ago_seconds(seconds), do: "#{div(seconds, 604_800)}w"

  defp author_name(%{author: %{kind: :user}}), do: "You"
  defp author_name(%{author: %{name: name}}) when is_binary(name), do: name
  defp author_name(_message), do: "Assistant"

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["app", @workers != [] && "has-workers"]}>
      <aside id="sidebar" class="sidebar">
        <div class="brand">
          <.link patch="/" class="wordmark">ReyCode</.link>
          <button
            class="icon-button menu-toggle"
            phx-click={JS.toggle_class("open", to: "#sidebar")}
            aria-label="Show conversations"
          >
            ☰
          </button>
        </div>
        <.link patch="/" class="new-chat">New conversation</.link>
        <nav class="sessions" aria-label="Conversations">
          <section :for={group <- @groups} class="group">
            <h2 title={group.workspace}>{group.name}</h2>
            <.link
              :for={item <- group.sessions}
              patch={"/sessions/#{item.id}"}
              class={["session", item.id == @id && "selected"]}
              aria-current={item.id == @id && "page"}
            >
              <span class="session-title">{item.title}</span>
              <span :if={item.working?} class="dot" title="Working"></span>
              <span class="ago">{item.ago}</span>
            </.link>
          </section>
          <p :if={@groups == []} class="empty-note">
            Conversations you start appear here.
          </p>
        </nav>
      </aside>

      <main class="conversation">
        <.home :if={is_nil(@id)} workspaces={@workspaces} notice={@notice} />
        <.missing :if={@id && is_nil(@session)} />
        <.thread
          :if={@session}
          session={@session}
          messages={@messages}
          tool_request={@tool_request}
          retry_turn_id={@retry_turn_id}
          question={@question}
          notice={@notice}
        />
      </main>

      <aside :if={@workers != []} class="workers" aria-label="Workers">
        <h2>Workers <span class="count">{length(@workers)}</span></h2>
        <.worker :for={worker <- @workers} worker={worker} />
      </aside>
    </div>
    """
  end

  defp home(assigns) do
    ~H"""
    <section class="home">
      <h1>What should we work on?</h1>
      <form :if={@workspaces != []} phx-submit="start" class="box" id="start" phx-hook="Composer">
        <textarea
          name="body"
          rows="4"
          placeholder="Describe the task. The assistant can start workers for parallel searches."
          aria-label="First message"
          autofocus
        ></textarea>
        <div class="box-row">
          <label class="workspace-chip">
            <span class="sr-only">Workspace</span>
            <select name="workspace">
              <option :for={workspace <- @workspaces} value={workspace}>
                {Path.basename(workspace)}
              </option>
            </select>
          </label>
          <button class="primary">Start</button>
        </div>
      </form>
      <p :if={@workspaces == []} class="empty-note">
        Open ReyCode in a project folder first; its workspace will appear here.
      </p>
      <p :if={@notice} class="notice" role="alert">{@notice}</p>
    </section>
    """
  end

  defp missing(assigns) do
    ~H"""
    <section class="home">
      <h1>This conversation no longer exists.</h1>
      <.link patch="/" class="new-chat inline">Start a new one</.link>
    </section>
    """
  end

  defp thread(assigns) do
    ~H"""
    <header class="thread-head">
      <div>
        <h1>{@session.title || "Untitled conversation"}</h1>
        <p class="workspace" title={@session.workspace}>{@session.workspace}</p>
      </div>
      <span :if={@session.active_turn_id} class="working">Working</span>
    </header>

    <div id="timeline" class="timeline" phx-hook="StickToBottom">
      <p :if={@messages == []} class="empty-note">No messages yet.</p>
      <article
        :for={message <- @messages}
        :key={message.id}
        class={["message", message.user? && "from-you", message.failed? && "failed"]}
      >
        <div :if={not message.user?} class="author">{message.name}</div>
        <div class={[
          "prose",
          message.user? && "bubble",
          message.streaming? && "streaming"
        ]}>
          {Phoenix.HTML.raw(message.html)}
        </div>
        <ul :if={elem(message.tools, 0) != []} class="tools">
          <li :if={elem(message.tools, 1) > 0} class="tool more">
            {elem(message.tools, 1)} earlier steps
          </li>
          <li :for={tool <- elem(message.tools, 0)} class={["tool", tool.state]}>
            <span class="tool-label">{tool.label}</span>
            <span :if={tool.target} class="tool-target">{tool.target}</span>
          </li>
        </ul>
        <p :if={message.error} class="error">{message.error}</p>
      </article>
      <div :if={@retry_turn_id} class="retry">
        <button phx-click="retry">Try again</button>
      </div>
    </div>

    <div class="dock">
      <section :if={@tool_request} class="needs-you" aria-live="polite">
        <p>
          <strong>{@tool_request.agent}</strong> wants to run <code>{@tool_request.tool}</code>
        </p>
        <pre class="args">{@tool_request.arguments}</pre>
        <div class="actions">
          <button
            class="primary"
            phx-click="tool"
            phx-value-invocation={@tool_request.invocation_id}
            phx-value-run={@tool_request.run_id}
            phx-value-decision="approve"
          >
            Approve
          </button>
          <button
            phx-click="tool"
            phx-value-invocation={@tool_request.invocation_id}
            phx-value-run={@tool_request.run_id}
            phx-value-decision="deny"
          >
            Deny
          </button>
        </div>
      </section>

      <form
        :if={@question}
        class="needs-you"
        phx-submit="answer"
        id={"question-#{@question.request.id}"}
      >
        <input type="hidden" name="invocation" value={@question.invocation_id} />
        <input type="hidden" name="request" value={@question.request.id} />
        <fieldset :for={item <- @question.request.questions}>
          <legend>{item.question}</legend>
          <label :for={option <- item.options} class="option">
            <input
              type={if item.multi?, do: "checkbox", else: "radio"}
              name={if item.multi?, do: "q-#{item.id}[]", else: "q-#{item.id}"}
              value={option.id}
              checked={option.id == item.recommended_id}
            />
            <span>
              {option.label}
              <span :if={option.id == item.recommended_id} class="hint">Recommended</span>
              <span :if={option.description not in [nil, ""]} class="hint block">
                {option.description}
              </span>
            </span>
          </label>
          <input
            :if={item.allow_other?}
            type="text"
            name={"other-#{item.id}"}
            placeholder="Or type your own answer"
            class="other"
          />
        </fieldset>
        <div class="actions"><button class="primary">Send answer</button></div>
      </form>

      <p :if={@notice} class="notice" role="alert">{@notice}</p>

      <form class="box" phx-submit="send" phx-hook="Composer" id="composer">
        <textarea
          name="body"
          rows="2"
          aria-label="Message"
          placeholder={
            if @session.active_turn_id,
              do: "Add a follow-up. It runs when the current work finishes.",
              else: "Message the assistant"
          }
        ></textarea>
        <div class="box-row">
          <span class="hint">Enter to send, Shift+Enter for a new line</span>
          <button :if={@session.active_turn_id} type="button" phx-click="stop">Stop</button>
          <button class="primary">Send</button>
        </div>
      </form>
    </div>
    """
  end

  defp worker(assigns) do
    ~H"""
    <article class={["worker", "status-#{@worker.status}"]}>
      <header>
        <strong>{@worker.name}</strong>
        <span class="state">{status_label(@worker.status)}</span>
      </header>
      <p class="meta">{@worker.model || "Default model"}, {@worker.tool_count} steps</p>
      <details :if={@worker.report} open={@worker.status != :completed}>
        <summary>Report</summary>
        <div class="report">{@worker.report}</div>
      </details>
      <div :if={@worker.diff} class="changes">
        <p>Changes are ready in an isolated copy.</p>
        <pre class="diff"><span :for={line <- @worker.diff} class={diff_class(line)}>{line}</span></pre>
        <div class="actions">
          <button
            class="primary"
            phx-click="merge"
            phx-value-invocation={@worker.id}
            phx-value-decision="apply"
          >
            Apply changes
          </button>
          <button
            phx-click="merge"
            phx-value-invocation={@worker.id}
            phx-value-decision="discard"
            data-confirm="Discard these changes? This cannot be undone."
          >
            Discard
          </button>
        </div>
      </div>
    </article>
    """
  end

  defp status_label(:waiting_tool_approval), do: "Needs you"
  defp status_label(:awaiting_delegation), do: "Waiting on workers"
  defp status_label(:running), do: "Running"
  defp status_label(:streaming), do: "Running"
  defp status_label(:queued), do: "Queued"
  defp status_label(:completed), do: "Done"
  defp status_label(:failed), do: "Failed"
  defp status_label(:cancelled), do: "Stopped"
  defp status_label(nil), do: "Unknown"
  defp status_label(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp diff_class("+++" <> _rest), do: "meta"
  defp diff_class("---" <> _rest), do: "meta"
  defp diff_class("@@" <> _rest), do: "hunk"
  defp diff_class("+" <> _rest), do: "add"
  defp diff_class("-" <> _rest), do: "del"
  defp diff_class(_line), do: nil
end
