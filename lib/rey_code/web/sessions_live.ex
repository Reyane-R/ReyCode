defmodule ReyCode.Web.SessionsLive do
  @moduledoc """
  Sessions, newest first, live from Engine broadcasts, plus a composer that
  starts a new conversation in a known workspace.
  """

  use Phoenix.LiveView

  alias ReyCode.Orchestration.{Engine, Projection}

  @sessions_max_count 100
  @workspaces_max_count 20
  @title_max_graphemes 60

  @impl true
  def mount(_params, _session, socket) do
    projection = if connected?(socket), do: Engine.subscribe(), else: Engine.snapshot()
    {:ok, socket |> assign(notice: nil) |> assign_projection(projection)}
  end

  @impl true
  def handle_info({:projection_snapshot, projection}, socket) do
    if projection.sequence > socket.assigns.sequence,
      do: {:noreply, assign_projection(socket, projection)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("start", %{"body" => body, "workspace" => workspace}, socket) do
    with false <- String.trim(body) == "",
         source when is_binary(source) <-
           Projection.newest_session_id_for_workspace(socket.assigns.projection, workspace),
         {:ok, session_id} <- Engine.create_session(source, title(body)),
         {:ok, _turn_id} <- Engine.post_message(session_id, body, :direct) do
      {:noreply, push_navigate(socket, to: "/sessions/#{session_id}")}
    else
      true ->
        {:noreply, socket}

      nil ->
        {:noreply, assign(socket, notice: "Unknown workspace")}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "Could not start: #{inspect(reason)}")}
    end
  end

  # Same title rule as the TUI: the first words of the opening message.
  defp title(body) do
    title = body |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")

    if String.length(title) > @title_max_graphemes,
      do: String.slice(title, 0, @title_max_graphemes) <> "…",
      else: title
  end

  defp assign_projection(socket, projection) do
    sessions =
      projection.session_order
      |> Enum.reverse()
      |> Enum.take(@sessions_max_count)
      |> Enum.map(&Map.fetch!(projection.sessions, &1))

    workspaces =
      sessions |> Enum.map(& &1.workspace) |> Enum.uniq() |> Enum.take(@workspaces_max_count)

    assign(socket,
      projection: projection,
      sequence: projection.sequence,
      sessions: sessions,
      workspaces: workspaces
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>ReyCode</h1>
      <form :if={@workspaces != []} phx-submit="start" class="action-card start">
        <textarea name="body" rows="3" placeholder="Start a new conversation…" required></textarea>
        <div class="composer-row">
          <select name="workspace">
            <option :for={workspace <- @workspaces} value={workspace}>{workspace}</option>
          </select>
          <button class="primary">Start</button>
        </div>
        <div :if={@notice} class="notice">{@notice}</div>
      </form>
      <h2>Sessions</h2>
      <div class="list">
        <.link :for={session <- @sessions} navigate={"/sessions/#{session.id}"}>
          <div>
            {session.title || "Untitled session"}<span
              :if={session.active_turn_id}
              class="pill pill-running"
            >working</span>
          </div>
          <div class="muted">{session.workspace} · {length(session.message_order)} messages</div>
        </.link>
      </div>
    </main>
    """
  end
end
