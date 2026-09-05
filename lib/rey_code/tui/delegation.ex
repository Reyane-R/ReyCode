defmodule ReyCode.TUI.Delegation do
  @moduledoc "Owns explicit task delegation to one user-created task participant."

  use Breeze.Component
  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.Engine
  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.{Notice, SlashPalette, State}

  @spec initial() :: map()
  def initial, do: %{step: :agents, index: 0, participant_id: nil, task: ""}

  @spec open(map()) :: map()
  def open(term) do
    case task_participants(term) do
      [] ->
        SlashPalette.close(term, Notice.new(:warning, "Create a task agent with /agent first"))

      _participants ->
        Component.assign(term,
          modal: :delegation,
          slash: nil,
          delegation: initial(),
          notice: nil
        )
    end
  end

  @doc "Opens task entry for one revalidated task Participant."
  @spec open_for(map(), String.t()) :: map()
  def open_for(term, participant_id) do
    case Enum.find(task_participants(term), &(&1.id == participant_id)) do
      nil ->
        SlashPalette.close(
          term,
          Notice.new(:warning, "The selected task agent is no longer available")
        )

      participant ->
        term
        |> Component.assign(
          modal: :delegation,
          slash: nil,
          delegation: %{
            initial()
            | step: :task,
              participant_id: participant.id
          },
          notice: nil
        )
        |> View.focus("delegated-task")
    end
  end

  @spec focus(map()) :: map()
  def focus(%{assigns: %{delegation: %{step: :task}}} = term),
    do: View.focus(term, "delegated-task")

  def focus(term), do: term

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, %{assigns: %{delegation: %{step: :agents}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(task_participants(term))
    index = Integer.mod(term.assigns.delegation.index + offset, count)
    {:noreply, put_delegation(term, %{term.assigns.delegation | index: index})}
  end

  def handle_input("Enter", %{assigns: %{delegation: %{step: :agents}}} = term),
    do: {:noreply, select_participant(term)}

  def handle_input("Enter", %{assigns: %{delegation: %{step: :task}}} = term),
    do: submit(term)

  def handle_input("Escape", term), do: {:noreply, cancel(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("delegated_task_changed", %{value: value}, term),
    do: {:noreply, put_task(term, value)}

  def handle_event("delegated_task_submitted", %{value: value}, term),
    do: term |> put_task(value) |> delegate()

  def handle_event(_event, _payload, _term), do: :unhandled

  @spec submit(map()) :: {:noreply, map()}
  def submit(%{assigns: %{delegation: %{step: :agents}}} = term),
    do: {:noreply, select_participant(term)}

  def submit(term), do: delegate(term)

  defp select_participant(term) do
    participant = Enum.at(task_participants(term), term.assigns.delegation.index)

    term
    |> put_delegation(%{
      term.assigns.delegation
      | step: :task,
        participant_id: participant.id
    })
    |> View.focus("delegated-task")
  end

  defp delegate(term) do
    if String.trim(term.assigns.delegation.task) == "" do
      {:noreply, Component.assign(term, notice: Notice.new(:warning, "Task is required"))}
    else
      case State.ensure_session(term, term.assigns.delegation.task) do
        {:ok, session_term} ->
          run_delegation(session_term)

        {:error, reason} ->
          {:noreply,
           Component.assign(term,
             notice: Notice.new(:error, "Could not start session: #{reason}")
           )}
      end
    end
  end

  defp run_delegation(term) do
    state = term.assigns.delegation

    case Engine.delegate_task(
           term.assigns.selected_session_id,
           state.participant_id,
           state.task,
           term.assigns.engine
         ) do
      {:ok, _turn_id} ->
        name = selected_participant(term).name

        {:noreply,
         term
         |> Component.assign(
           modal: nil,
           home: false,
           delegation: initial(),
           notice: Notice.new(:success, "Task delegated to #{name}")
         )
         |> View.focus("prompt")}

      {:error, {:participants_unconfigured, _ids}} ->
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:warning, "Configure this agent's model with /agents")
         )}

      {:error, reason} ->
        {:noreply,
         Component.assign(term, notice: Notice.new(:error, "Could not delegate task: #{reason}"))}
    end
  end

  defp cancel(term) do
    term
    |> Component.assign(modal: nil, delegation: initial(), notice: nil)
    |> View.focus("prompt")
  end

  defp put_task(term, value) do
    put_delegation(term, %{term.assigns.delegation | task: value})
  end

  defp put_delegation(term, delegation), do: Component.assign(term, delegation: delegation)

  defp selected_participant(term) do
    assigns = term_assigns(term)
    Enum.find(task_participants(term), &(&1.id == assigns.delegation.participant_id))
  end

  defp selected_name(term), do: selected_participant(term).name
  defp selected_responsibility(term), do: selected_participant(term).perspective

  defp task_participants(term) do
    assigns = term_assigns(term)

    assigns.projection.sessions[assigns.selected_session_id].participants
    |> Enum.filter(&(&1.kind == :task))
  end

  defp term_assigns(%{assigns: assigns}), do: assigns
  defp term_assigns(assigns), do: assigns

  attr :term, :map, required: true

  @doc "Renders task-agent selection and task entry."
  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Delegate a task</box>
        <box class="text-muted">Exactly one task agent will run.</box>
      </box>
      <box :if={@term.delegation.step == :agents} class="pt-3 w-full">
        <box class="font-bold">Choose a task agent</box>
        <box
          :for={{participant, index} <- Enum.with_index(task_participants(@term))}
          class={row_class(index, @term.delegation.index)}
        >
          {marker(index, @term.delegation.index)} {participant.name}  ·  {Presentation.short_runtime_label(participant)}
        </box>
      </box>
      <box :if={@term.delegation.step == :task} class="pt-3 w-full">
        <box class="font-bold">Task for {selected_name(@term)}</box>
        <box class="text-muted">{selected_responsibility(@term)}</box>
        <.textarea
          id="delegated-task"
          textarea-value={@term.delegation.task}
          textarea-placeholder="Describe the concrete task and expected result..."
          textarea-submit-on-enter={true}
          br-change="delegated_task_changed"
          br-submit="delegated_task_submitted"
          class="w-full h-6"
        />
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-2 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select   Esc cancel</box>
    </box>
    """
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
