defmodule ReyCode.TUI.AgentProfile do
  @moduledoc "Owns the user-created task-agent profile form."

  use Breeze.Component
  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.TUI.{Settings, SlashPalette}

  @spec initial() :: map()
  def initial, do: %{step: :name, name: "", responsibility: ""}

  @spec open(map()) :: map()
  def open(term) do
    term
    |> Component.assign(modal: :agent_profile, slash: nil, agent_profile: initial(), notice: nil)
    |> View.focus("agent-name")
  end

  @spec focus(map()) :: map()
  def focus(%{assigns: %{agent_profile: %{step: :name}}} = term),
    do: View.focus(term, "agent-name")

  def focus(term), do: View.focus(term, "agent-responsibility")

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("agent_name_changed", %{value: value}, term),
    do: {:noreply, put_value(term, :name, value)}

  def handle_event("agent_name_submitted", %{value: value}, term) do
    term = put_value(term, :name, value)

    if String.trim(value) == "" do
      {:noreply, Component.assign(term, notice: "Agent name is required")}
    else
      {:noreply,
       term
       |> put_step(:responsibility)
       |> Component.assign(notice: nil)
       |> View.focus("agent-responsibility")}
    end
  end

  def handle_event("agent_responsibility_changed", %{value: value}, term),
    do: {:noreply, put_value(term, :responsibility, value)}

  def handle_event("agent_responsibility_submitted", %{value: value}, term) do
    term |> put_value(:responsibility, value) |> create()
  end

  def handle_event(_event, _payload, _term), do: :unhandled

  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{agent_profile: %{step: :name, name: name}}} = term),
    do: handle_event("agent_name_submitted", %{value: name}, term)

  def submit(%{assigns: %{agent_profile: %{responsibility: responsibility}}} = term),
    do: handle_event("agent_responsibility_submitted", %{value: responsibility}, term)

  defp create(term) do
    profile = term.assigns.agent_profile

    case Engine.add_task_participant(
           term.assigns.selected_room_id,
           profile.name,
           profile.responsibility,
           term.assigns.engine
         ) do
      {:ok, participant_id} ->
        {:noreply,
         term
         |> Component.assign(agent_profile: initial())
         |> Settings.open_for(participant_id)}

      {:error, :participant_responsibility_required} ->
        {:noreply, Component.assign(term, notice: "Responsibility is required")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not create agent: #{reason}")}
    end
  end

  defp cancel(term) do
    term
    |> SlashPalette.clear()
    |> Component.assign(modal: nil, agent_profile: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp put_value(term, field, value) do
    Component.assign(term, agent_profile: Map.put(term.assigns.agent_profile, field, value))
  end

  defp put_step(term, step) do
    Component.assign(term, agent_profile: %{term.assigns.agent_profile | step: step})
  end

  attr :term, :map, required: true

  @doc "Renders the task-agent profile form."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Create a task agent</box>
        <box class="text-muted">Task agents run only when you explicitly delegate work.</box>
      </box>
      <box :if={@term.agent_profile.step == :name} class="pt-3 w-full">
        <box class="text-muted">AGENT NAME</box>
        <.textarea
          id="agent-name"
          textarea-value={@term.agent_profile.name}
          textarea-placeholder="Release"
          textarea-submit-on-enter={true}
          br-change="agent_name_changed"
          br-submit="agent_name_submitted"
          class="w-full h-3"
        />
      </box>
      <box :if={@term.agent_profile.step == :responsibility} class="pt-3 w-full">
        <box class="text-muted">STANDING RESPONSIBILITY</box>
        <.textarea
          id="agent-responsibility"
          textarea-value={@term.agent_profile.responsibility}
          textarea-placeholder="Commit, push, and deploy approved changes"
          textarea-submit-on-enter={true}
          br-change="agent_responsibility_changed"
          br-submit="agent_responsibility_submitted"
          class="w-full h-5"
        />
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">Enter continue   Esc cancel</box>
    </box>
    """
  end
end
