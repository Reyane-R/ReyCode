defmodule ReyCode.TUI.OperatorQuestion do
  @moduledoc "Interaction owner and renderer for pending OperatorQuestions."

  use Breeze.Component
  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Projection}
  alias ReyCode.TUI.SlashPalette

  @preview_line_count 8

  @spec initial() :: map()
  def initial,
    do: %{
      invocation_id: nil,
      question_id: nil,
      step: :options,
      index: 0,
      selected_ids: [],
      other: ""
    }

  @spec open(map()) :: map()
  def open(term) do
    invocation =
      Projection.pending_question_invocation(
        term.assigns.projection,
        term.assigns.selected_session_id
      )

    if invocation do
      question = invocation.coordination.pending_question

      term
      |> SlashPalette.clear()
      |> Component.assign(
        modal: :operator_question,
        operator_question: %{
          initial()
          | invocation_id: invocation.id,
            question_id: question.id,
            index: recommended_index(question)
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
  def submit(term), do: submit_answer(term)

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, %{assigns: %{operator_question: %{step: :options}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    index = Integer.mod(term.assigns.operator_question.index + offset, option_count(term))

    {:noreply,
     Component.assign(term, operator_question: %{term.assigns.operator_question | index: index})}
  end

  def handle_input(" ", %{assigns: %{operator_question: %{step: :options}}} = term) do
    {:noreply, toggle_current(term)}
  end

  def handle_input("Enter", %{assigns: %{operator_question: %{step: :options}}} = term) do
    question = question(term)

    case current_choice(term) do
      :other ->
        {:noreply, put_step(term, :other)}

      option ->
        if question.multi?, do: submit_answer(term), else: answer(term, [option.id], nil)
    end
  end

  def handle_input("Escape", %{assigns: %{operator_question: %{step: :other}}} = term),
    do: {:noreply, put_step(term, :options)}

  def handle_input("Escape", term), do: {:noreply, close(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("question_other_changed", %{value: value}, term),
    do: {:noreply, put_other(term, value)}

  def handle_event("question_other_submitted", %{value: value}, term),
    do: term |> put_other(value) |> submit_answer()

  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    invocation = assigns.term.projection.invocations[assigns.term.operator_question.invocation_id]
    question = invocation.coordination.pending_question

    assigns =
      assigns
      |> Map.put(:question, question)
      |> Map.put(:preview_lines, preview_lines(question, assigns.term.operator_question.index))

    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3 overflow-hidden">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Operator question</box>
        <box class="text-muted">{question_mode(@question)}</box>
      </box>
      <box class="pt-3 font-bold">{@question.question}</box>
      <box :if={@term.operator_question.step == :options} class="pt-2 w-full">
        <box
          :for={{option, index} <- Enum.with_index(@question.options)}
          class={row_class(index, @term.operator_question.index)}
        >
          {selection_marker(option, index, @term.operator_question, @question)} {option.label}{recommended(option, @question)}{description(option)}
        </box>
        <box
          :if={@question.allow_other?}
          class={row_class(length(@question.options), @term.operator_question.index)}
        >
          {other_marker(@term.operator_question, @question)} Other · type a bounded answer
        </box>
        <box :if={@preview_lines != []} class="pt-2 px-1 w-full bg-panel border-l border-secondary">
          <box :for={line <- @preview_lines} class="text-muted">{line}</box>
        </box>
      </box>
      <box :if={@term.operator_question.step == :other} class="pt-3 w-full">
        <box class="text-muted">OTHER ANSWER</box>
        <.textarea
          id="question-other"
          textarea-value={@term.operator_question.other}
          textarea-placeholder="Type the decision context the Invocation needs"
          textarea-submit-on-enter={true}
          br-change="question_other_changed"
          br-submit="question_other_submitted"
          class="w-full h-5 border focus:border-primary bg-surface"
        />
      </box>
      <box :if={not is_nil(@term.notice)} class="pt-2 text-error">{@term.notice}</box>
      <box class="pt-2 text-muted">{controls(@question, @term.operator_question.step)}</box>
    </box>
    """
  end

  defp toggle_current(term) do
    question = question(term)

    case current_choice(term) do
      :other ->
        put_step(term, :other)

      option when question.multi? ->
        selected = term.assigns.operator_question.selected_ids

        selected =
          if option.id in selected,
            do: List.delete(selected, option.id),
            else: selected ++ [option.id]

        Component.assign(term,
          operator_question: %{term.assigns.operator_question | selected_ids: selected}
        )

      option ->
        Component.assign(term,
          operator_question: %{term.assigns.operator_question | selected_ids: [option.id]}
        )
    end
  end

  defp submit_answer(term) do
    state = term.assigns.operator_question
    answer(term, state.selected_ids, normalize_other(state.other))
  end

  defp answer(term, option_ids, other) do
    question = question(term)
    selection = %{option_ids: option_ids, other: other}

    case Engine.answer_question(
           term.assigns.operator_question.invocation_id,
           question.id,
           selection,
           term.assigns.engine
         ) do
      :ok ->
        {:noreply, close(term, answer_notice(question, option_ids, other))}

      {:error, reason} ->
        {:noreply, Component.assign(term, notice: "Could not answer: #{reason}")}
    end
  end

  defp question(term) do
    term.assigns.projection.invocations[term.assigns.operator_question.invocation_id].coordination.pending_question
  end

  defp current_choice(term) do
    question = question(term)
    index = term.assigns.operator_question.index
    if index == length(question.options), do: :other, else: Enum.at(question.options, index)
  end

  defp option_count(term),
    do: length(question(term).options) + if(question(term).allow_other?, do: 1, else: 0)

  defp put_step(term, step),
    do: Component.assign(term, operator_question: %{term.assigns.operator_question | step: step})

  defp put_other(term, value),
    do:
      Component.assign(term, operator_question: %{term.assigns.operator_question | other: value})

  defp close(term, notice \\ nil) do
    term
    |> Component.assign(modal: nil, operator_question: initial(), notice: notice)
    |> View.focus("prompt")
  end

  defp recommended_index(question),
    do: Enum.find_index(question.options, &(&1.id == question.recommended_id)) || 0

  defp preview_lines(question, index) do
    case Enum.at(question.options, index) do
      %{preview: preview} when preview != "" ->
        preview |> String.split("\n") |> Enum.take(@preview_line_count)

      _other ->
        []
    end
  end

  defp question_mode(%{multi?: true}), do: "Choose one or more · the Invocation is paused"
  defp question_mode(_question), do: "Choose one · the Invocation is paused"
  defp controls(_question, :other), do: "Enter submit Other   Esc options"

  defp controls(%{multi?: true}, :options),
    do: "Space toggle   Enter submit   Arrow keys or j/k move   Esc leave waiting"

  defp controls(_question, :options),
    do: "Enter select   Arrow keys or j/k move   Esc leave waiting"

  defp selection_marker(option, index, state, %{multi?: true}) do
    selected = if option.id in state.selected_ids, do: "x", else: " "
    cursor = if index == state.index, do: ">", else: " "
    "#{cursor}[#{selected}]"
  end

  defp selection_marker(_option, index, state, _question),
    do: if(index == state.index, do: ">", else: " ")

  defp other_marker(state, question) do
    cursor = if state.index == length(question.options), do: ">", else: " "
    if question.multi?, do: "#{cursor}[ ]", else: cursor
  end

  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp recommended(%{id: id}, %{recommended_id: id}), do: " · recommended"
  defp recommended(_option, _question), do: ""
  defp description(%{description: ""}), do: ""
  defp description(option), do: " · #{option.description}"

  defp normalize_other(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp answer_notice(question, option_ids, other) do
    labels = question.options |> Enum.filter(&(&1.id in option_ids)) |> Enum.map(& &1.label)
    labels = labels ++ if(other, do: ["Other"], else: [])
    "Answered: #{Enum.join(labels, ", ")}"
  end
end
