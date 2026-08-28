defmodule ReyCode.TUI.OperatorQuestion do
  @moduledoc "Interaction owner and renderer for pending OperatorQuestions."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Projection}
  alias ReyCode.TUI.SlashPalette

  @spec initial() :: map()
  def initial, do: %{invocation_id: nil, question_id: nil, index: 0}

  @spec open(map()) :: map()
  def open(term) do
    invocation =
      Projection.pending_question_invocation(
        term.assigns.projection,
        term.assigns.selected_room_id
      )

    if invocation do
      term
      |> SlashPalette.clear()
      |> Component.assign(
        modal: :operator_question,
        operator_question: %{
          invocation_id: invocation.id,
          question_id: invocation.coordination.pending_question.id,
          index: recommended_index(invocation.coordination.pending_question)
        },
        notice: nil
      )
    else
      SlashPalette.close(term, "No Operator question is waiting")
    end
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: answer(term)

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = length(question(term).options)
    index = Integer.mod(term.assigns.operator_question.index + offset, count)

    {:noreply,
     Component.assign(term, operator_question: %{term.assigns.operator_question | index: index})}
  end

  def handle_input("Enter", term), do: answer(term)
  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    invocation = assigns.term.projection.invocations[assigns.term.operator_question.invocation_id]
    assigns = Map.put(assigns, :question, invocation.coordination.pending_question)

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Operator question</box>
        <box class="text-muted">The Invocation is paused until one option is selected.</box>
      </box>
      <box class="pt-3 font-bold">{@question.question}</box>
      <box class="pt-2 w-full">
        <box
          :for={{option, index} <- Enum.with_index(@question.options)}
          class={row_class(index, @term.operator_question.index)}
        >
          {marker(index, @term.operator_question.index)} {option.label}{recommended(option, @question)}{description(option)}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select   Esc leave waiting</box>
    </box>
    """
  end

  defp answer(term) do
    question = question(term)
    option = Enum.at(question.options, term.assigns.operator_question.index)

    case Engine.answer_question(
           term.assigns.operator_question.invocation_id,
           question.id,
           option.id,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply, close(term, "Answered: #{option.label}")}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not answer: #{reason}")}
    end
  end

  defp question(term) do
    term.assigns.projection.invocations[term.assigns.operator_question.invocation_id].coordination.pending_question
  end

  defp close(term, notice \\ nil) do
    term
    |> Component.assign(modal: nil, operator_question: initial(), notice: notice)
    |> View.focus("prompt")
  end

  defp recommended_index(question) do
    Enum.find_index(question.options, &(&1.id == question.recommended_id)) || 0
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
  defp recommended(%{id: id}, %{recommended_id: id}), do: " · recommended"
  defp recommended(_option, _question), do: ""
  defp description(%{description: ""}), do: ""
  defp description(option), do: " · #{option.description}"
end
