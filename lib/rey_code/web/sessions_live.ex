defmodule ReyCode.Web.SessionsLive do
  @moduledoc "Read-only list of Sessions, newest first, live from Engine broadcasts."

  use Phoenix.LiveView

  alias ReyCode.Orchestration.Engine

  @sessions_max_count 100

  @impl true
  def mount(_params, _session, socket) do
    projection = if connected?(socket), do: Engine.subscribe(), else: Engine.snapshot()
    {:ok, assign_projection(socket, projection)}
  end

  @impl true
  def handle_info({:projection_snapshot, projection}, socket) do
    if projection.sequence > socket.assigns.sequence,
      do: {:noreply, assign_projection(socket, projection)},
      else: {:noreply, socket}
  end

  defp assign_projection(socket, projection) do
    sessions =
      projection.session_order
      |> Enum.reverse()
      |> Enum.take(@sessions_max_count)
      |> Enum.map(&Map.fetch!(projection.sessions, &1))

    assign(socket, sequence: projection.sequence, sessions: sessions)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Sessions</h1>
      <p class="muted">Read-only. Updates live as the engine records events.</p>
      <div class="list">
        <.link :for={session <- @sessions} navigate={"/sessions/#{session.id}"}>
          <div>{session.title || "Untitled session"}</div>
          <div class="muted">{session.workspace} · {length(session.message_order)} messages</div>
        </.link>
      </div>
    </main>
    """
  end
end
