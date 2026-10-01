defmodule ReyCode.Web.SessionLive do
  @moduledoc "Read-only live timeline for one Session, with its delegated workers side by side."

  use Phoenix.LiveView

  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.TextBuffer

  @messages_max_count 200
  @workers_max_count 24
  @report_max_bytes 4_096

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    projection = if connected?(socket), do: Engine.subscribe(), else: Engine.snapshot()
    {:ok, socket |> assign(id: id) |> assign_projection(projection)}
  end

  @impl true
  def handle_info({:projection_snapshot, projection}, socket) do
    if projection.sequence > socket.assigns.sequence,
      do: {:noreply, assign_projection(socket, projection)},
      else: {:noreply, socket}
  end

  defp assign_projection(socket, projection) do
    session = Map.get(projection.sessions, socket.assigns.id)

    messages =
      if session,
        do:
          session.message_order
          |> Enum.take(-@messages_max_count)
          |> Enum.map(&Map.fetch!(projection.messages, &1)),
        else: []

    assign(socket,
      sequence: projection.sequence,
      session: session,
      messages: messages,
      workers: workers(projection, socket.assigns.id)
    )
  end

  # ponytail: scans every Invocation per broadcast; index children by Session if this shows up in profiles.
  defp workers(projection, session_id) do
    projection.invocations
    |> Map.values()
    |> Enum.filter(&(&1.session_id == session_id and is_binary(&1.delegated_from_invocation_id)))
    |> Enum.map(&worker(&1, Map.get(projection.messages, &1.message_id)))
    |> Enum.sort_by(& &1.sequence, :desc)
    |> Enum.take(@workers_max_count)
  end

  defp worker(invocation, message) do
    %{
      id: invocation.id,
      name: invocation.participant.name,
      model: invocation.participant.model,
      status: invocation.status,
      tool_count: length(invocation.tool_run_order),
      sequence: if(message, do: message.created_sequence, else: 0),
      report: report(message),
      diff: pending_diff(invocation.pending_tool_review)
    }
  end

  defp report(%{body: body}) when is_binary(body) and body != "" do
    if byte_size(body) > @report_max_bytes,
      do: TextBuffer.truncate_utf8(body, @report_max_bytes) <> "\n…",
      else: body
  end

  defp report(_message), do: nil

  # The diff lives in the projection only while the merge waits for an Apply/Discard decision.
  defp pending_diff(%{tool: "merge", arguments: %{"diff" => diff}}) when is_binary(diff),
    do: String.split(diff, "\n")

  defp pending_diff(_review), do: nil

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
    <main>
      <.link navigate="/" class="muted">← Sessions</.link>
      <h1>{@session.title || "Untitled session"}</h1>
      <p class="muted">{@session.workspace}</p>
      <section :if={@workers != []}>
        <h2>Workers <span class="muted">{length(@workers)}</span></h2>
        <div class="workers">
          <article :for={worker <- @workers} class="worker">
            <header>
              <strong>{worker.name}</strong>
              <span class={["pill", "pill-#{worker.status}"]}>{status_label(worker.status)}</span>
            </header>
            <div class="muted">{worker.model || "default model"} · {worker.tool_count} tool runs</div>
            <details :if={worker.report} open={worker.status != :completed}>
              <summary>Report</summary>
              <div class="body">{worker.report}</div>
            </details>
            <details :if={worker.diff} open>
              <summary>Diff waiting for Apply / Discard</summary>
              <pre class="diff"><span :for={line <- worker.diff} class={diff_class(line)}>{line}</span></pre>
            </details>
          </article>
        </div>
      </section>
      <h2>Timeline</h2>
      <div :for={message <- @messages} class="msg">
        <div class={["who", message.author && message.author.kind == :agent && "agent"]}>
          {author_name(message)}
          <span :if={message.status not in [nil, :completed]} class="status">{message.status}</span>
        </div>
        <div class="body">{message.body}</div>
      </div>
    </main>
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
