defmodule ReyCode.Web.SessionLive do
  @moduledoc "Read-only live timeline for one Session."

  use Phoenix.LiveView

  alias ReyCode.Orchestration.Engine

  @messages_max_count 200

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

    assign(socket, sequence: projection.sequence, session: session, messages: messages)
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
    <main>
      <.link navigate="/" class="muted">← Sessions</.link>
      <h1>{@session.title || "Untitled session"}</h1>
      <p class="muted">{@session.workspace}</p>
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

  defp author_name(%{author: %{name: name}}) when is_binary(name), do: name
  defp author_name(_message), do: "Unknown"
end
