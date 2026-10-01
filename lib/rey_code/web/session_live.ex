defmodule ReyCode.Web.SessionLive do
  @moduledoc """
  Live timeline for one Session with its delegated workers side by side.

  Owner actions go through the same Engine calls the TUI uses: post a
  message, stop the active Turn, approve or deny a tool request, answer an
  OperatorQuestion, and apply or discard an isolated worker patch. The view
  never writes events itself.
  """

  use Phoenix.LiveView

  alias ReyCode.Orchestration.{Engine, Projection}
  alias ReyCode.Provider.TextBuffer

  @messages_max_count 200
  @workers_max_count 24
  @report_max_bytes 4_096
  @arguments_max_bytes 4_096

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    projection = if connected?(socket), do: Engine.subscribe(), else: Engine.snapshot()
    {:ok, socket |> assign(id: id, notice: nil) |> assign_projection(projection)}
  end

  @impl true
  def handle_info({:projection_snapshot, projection}, socket) do
    if projection.sequence > socket.assigns.sequence,
      do: {:noreply, assign_projection(socket, projection)},
      else: {:noreply, socket}
  end

  @impl true
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
    case socket.assigns.session.active_turn_id do
      nil -> {:noreply, socket}
      turn_id -> reply(socket, Engine.cancel_turn(turn_id, "Cancelled by user"), "stop")
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

  defp assign_projection(socket, projection) do
    id = socket.assigns.id
    session = Map.get(projection.sessions, id)

    assign(socket,
      sequence: projection.sequence,
      session: session,
      messages: messages(projection, session),
      workers: workers(projection, id),
      tool_request: tool_request(projection, session),
      question: question(projection, id)
    )
  end

  defp messages(_projection, nil), do: []

  # message_order is newest first; the timeline reads oldest to newest.
  defp messages(projection, session) do
    session.message_order
    |> Enum.take(@messages_max_count)
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(projection.messages, &1))
  end

  defp workers(projection, session_id) do
    projection
    |> Projection.delegated_invocations(session_id)
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

  @impl true
  def render(%{session: nil} = assigns) do
    ~H"""
    <main>
      <.link navigate="/" class="muted">← Sessions</.link>
      <h1>Session not found</h1>
    </main>
    """
  end

  def render(assigns) do
    ~H"""
    <main class="with-composer">
      <.link navigate="/" class="muted">← Sessions</.link>
      <h1>{@session.title || "Untitled session"}</h1>
      <p class="muted">{@session.workspace}</p>

      <section :if={@tool_request} class="action-card">
        <header>
          <strong>{@tool_request.agent} wants to run <code>{@tool_request.tool}</code></strong>
        </header>
        <pre class="args">{@tool_request.arguments}</pre>
        <div class="buttons">
          <button
            phx-click="tool"
            phx-value-invocation={@tool_request.invocation_id}
            phx-value-run={@tool_request.run_id}
            phx-value-decision="approve"
            class="primary"
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
        class="action-card"
        phx-submit="answer"
        id={"question-#{@question.request.id}"}
      >
        <input type="hidden" name="invocation" value={@question.invocation_id} />
        <input type="hidden" name="request" value={@question.request.id} />
        <fieldset :for={item <- @question.request.questions}>
          <legend><strong>{item.header}</strong> · {item.question}</legend>
          <label :for={option <- item.options} class="option">
            <input
              type={if item.multi?, do: "checkbox", else: "radio"}
              name={if item.multi?, do: "q-#{item.id}[]", else: "q-#{item.id}"}
              value={option.id}
              checked={option.id == item.recommended_id}
            />
            <span>
              {option.label}<span :if={option.id == item.recommended_id} class="muted"> (recommended)</span>
              <span :if={option.description not in [nil, ""]} class="muted"><br />{option.description}</span>
            </span>
          </label>
          <input
            :if={item.allow_other?}
            type="text"
            name={"other-#{item.id}"}
            placeholder="Other…"
            class="other"
          />
        </fieldset>
        <div class="buttons"><button class="primary">Send answers</button></div>
      </form>

      <section :if={@workers != []}>
        <h2>Workers <span class="muted">{length(@workers)}</span></h2>
        <div class="workers">
          <article :for={worker <- @workers} class="worker">
            <header>
              <strong>{worker.name}</strong>
              <span class={["pill", "pill-#{worker.status}"]}>{status_label(worker.status)}</span>
            </header>
            <div class="muted">
              {worker.model || "default model"} · {worker.tool_count} tool runs
            </div>
            <details :if={worker.report} open={worker.status != :completed}>
              <summary>Report</summary>
              <div class="body">{worker.report}</div>
            </details>
            <details :if={worker.diff} open>
              <summary>Changes waiting for you</summary>
              <pre class="diff"><span :for={line <- worker.diff} class={diff_class(line)}>{line}</span></pre>
              <div class="buttons">
                <button
                  phx-click="merge"
                  phx-value-invocation={worker.id}
                  phx-value-decision="apply"
                  class="primary"
                >
                  Apply
                </button>
                <button
                  phx-click="merge"
                  phx-value-invocation={worker.id}
                  phx-value-decision="discard"
                  data-confirm="Discard these changes?"
                >
                  Discard
                </button>
              </div>
            </details>
          </article>
        </div>
      </section>

      <h2>Timeline</h2>
      <div id="timeline" phx-hook="StickToBottom">
        <div :for={message <- @messages} :key={message.id} class="msg">
          <div class={["who", message.author && message.author.kind == :agent && "agent"]}>
            {author_name(message)}<span
              :if={message.status not in [nil, :completed]}
              class="status"
            >{message.status}</span>
          </div>
          <div class="body">{message.body}</div>
        </div>
      </div>
    </main>

    <form class="composer" phx-submit="send" phx-hook="Composer" id="composer">
      <div :if={@notice} class="notice">{@notice}</div>
      <div class="composer-row">
        <textarea
          name="body"
          rows="2"
          placeholder={
            if @session.active_turn_id, do: "Queue a follow-up…", else: "Message the assistant…"
          }
        ></textarea>
        <button class="primary">Send</button>
        <button :if={@session.active_turn_id} type="button" phx-click="stop">Stop</button>
      </div>
      <div class="muted hint">
        Enter to send · Shift+Enter for a new line<span :if={@session.active_turn_id}> · working…</span>
      </div>
    </form>
    """
  end

  defp status_label(:waiting_tool_approval), do: "needs you"
  defp status_label(:awaiting_delegation), do: "waiting on workers"
  defp status_label(nil), do: "unknown"
  defp status_label(status), do: status |> Atom.to_string() |> String.replace("_", " ")

  defp diff_class("+++" <> _rest), do: "meta"
  defp diff_class("---" <> _rest), do: "meta"
  defp diff_class("@@" <> _rest), do: "hunk"
  defp diff_class("+" <> _rest), do: "add"
  defp diff_class("-" <> _rest), do: "del"
  defp diff_class(_line), do: nil

  defp author_name(%{author: %{name: name}}) when is_binary(name), do: name
  defp author_name(_message), do: "Unknown"
end
