defmodule ReyCode.TUI.OperatorQuestion do
  @moduledoc "Compact interaction owner and renderer for pending OperatorQuestions."

  use Breeze.Component
  import Breeze.Blocks, except: [modal: 1]

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, Projection}
  alias ReyCode.Orchestration.OperatorQuestion, as: DurableQuestion
  alias ReyCode.TUI.{Action, Notice, SlashPalette}

  @preview_line_count 3
  @preview_line_max_codepoints 120
  @digit_keys ~w(1 2 3 4 5)

  @spec initial() :: map()
  def initial do
    %{
      invocation_id: nil,
      request_id: nil,
      tab_index: 0,
      option_index: 0,
      step: :options,
      answers: %{},
      option_indices: %{},
      request_states: %{}
    }
  end

  @spec open(map()) :: map()
  def open(term) do
    case pending_invocations(term) do
      [invocation | _rest] -> activate(term, invocation)
      [] -> SlashPalette.close(term, Notice.new(:info, "No Operator question is waiting"))
    end
  end

  @doc "Keeps an open picker aligned with Projection state and opens new requests automatically."
  @spec reconcile(map()) :: map()
  def reconcile(
        %{assigns: %{operator_question: %{}, projection: %{}, selected_session_id: session_id}} =
          term
      )
      when is_binary(session_id) do
    pending = pending_invocations(term)
    term = prune_request_states(term, pending)

    case term.assigns.modal do
      :operator_question -> reconcile_open(term, pending)
      nil when pending != [] -> activate(term, hd(pending))
      nil -> clear_request_states(term)
      _other -> term
    end
  end

  def reconcile(term), do: term

  @spec focus(map()) :: map()
  def focus(term), do: move_tab(term, 1)

  @spec submit(map()) :: {:noreply, map()}
  def submit(term) do
    if review?(term), do: submit_answers(term), else: handle_input("Enter", term)
  end

  @spec handle_input(String.t() | map(), map()) :: {:noreply, map()}
  def handle_input(%{"key" => "Tab", "shiftKey" => true}, term),
    do: {:noreply, move_tab(term, -1)}

  def handle_input(%{"key" => key}, term), do: handle_input(key, term)

  def handle_input(key, %{assigns: %{operator_question: %{step: :options}}} = term)
      when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    {:noreply, move_option(term, offset)}
  end

  def handle_input(key, term) when key in ["ArrowLeft", "Tab"],
    do: {:noreply, move_tab(term, if(key == "ArrowLeft", do: -1, else: 1))}

  def handle_input("ArrowRight", term), do: {:noreply, move_tab(term, 1)}

  def handle_input(key, term) when key in ["[", "PageUp"],
    do: {:noreply, switch_request(term, -1)}

  def handle_input(key, term) when key in ["]", "PageDown"],
    do: {:noreply, switch_request(term, 1)}

  def handle_input(key, term) when key in @digit_keys do
    {:noreply, choose_index(term, String.to_integer(key) - 1)}
  end

  def handle_input(" ", term), do: {:noreply, choose_current(term)}
  def handle_input("Enter", term), do: enter(term)

  def handle_input("Escape", %{assigns: %{operator_question: %{step: :other}}} = term),
    do: {:noreply, put_step(term, :options)}

  def handle_input("Escape", term), do: reject(term)
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event("question_other_changed", payload, term) do
    value = payload_value(payload, :value, "")
    {:noreply, put_other(term, value)}
  end

  def handle_event("question_other_submitted", payload, term) do
    value = payload_value(payload, :value, "")
    term |> put_other(value) |> finish_other()
  end

  def handle_event("question_confirm", _payload, term), do: submit_answers(term)

  def handle_event("question_tab_" <> index, _payload, term),
    do: {:noreply, put_tab(term, parse_index(index))}

  def handle_event("question_option_" <> index, _payload, term) do
    next = term |> choose_index(parse_index(index)) |> focus_after_option_click()
    {:noreply, next}
  end

  def handle_event("question_request_" <> index, _payload, term),
    do: {:noreply, switch_request_to(term, parse_index(index))}

  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def question_panel(assigns) do
    term =
      case assigns do
        %{term: term} -> term
        %{__breeze_caller_assigns__: caller} -> caller
      end

    state = term.operator_question
    invocation = Map.get(term.projection.invocations, state.invocation_id)
    request = invocation && normalize_request(invocation.coordination.pending_question)
    pending = pending_invocations_from_assigns(term)
    item = request && item_at(request.questions, state.tab_index)
    answer = item && answer_for(state, item.id)

    assigns =
      Map.merge(assigns, %{
        term: term,
        invocation: invocation,
        request: request,
        pending: pending,
        item: item,
        answer: answer,
        preview_lines: preview_lines(item, state.option_index),
        review_rows: review_rows(request, state.answers),
        request_position: request_position(pending, state.invocation_id),
        participant_name: participant_name(invocation)
      })

    ~H"""
    <box
      :if={not is_nil(@request)}
      class="h-14 w-full bg-surface border-t border-primary px-2 overflow-hidden"
    >
      <box class="inline w-full">
        <box class="font-bold text-primary">{@participant_name} asks</box>
        <box class="w-full text-right text-muted">
          Request {@request_position} · [ ] switch · Esc reject
        </box>
      </box>
      <box class="inline w-full border-b border-muted">
        <box
          :for={{question, index} <- Enum.with_index(@request.questions)}
          id={"question-tab-#{index}"}
          implicit={Action}
          br-change={"question_tab_#{index}"}
          class={tab_class(index, @term.operator_question.tab_index)}
        >
          {index + 1} {question.header}{answered_marker(@term.operator_question.answers, question.id)}
        </box>
        <box
          id="question-tab-review"
          implicit={Action}
          br-change={"question_tab_#{length(@request.questions)}"}
          class={tab_class(length(@request.questions), @term.operator_question.tab_index)}
        >
          Review
        </box>
      </box>
      <box :if={not is_nil(@item) and @term.operator_question.step == :options} class="w-full">
        <box class="font-bold">{@item.question}</box>
        <box
          :for={{option, index} <- Enum.with_index(@item.options)}
          id={"question-option-#{index}"}
          implicit={Action}
          br-change={"question_option_#{index}"}
          class={row_class(index, @term.operator_question.option_index)}
        >
          {index + 1}. {selection_marker(option, index, @term.operator_question, @item, @answer)} {option.label}{recommended(option, @item)}{description(option)}
        </box>
        <box
          :if={@item.allow_other?}
          id="question-option-other"
          implicit={Action}
          br-change={"question_option_#{length(@item.options)}"}
          class={row_class(length(@item.options), @term.operator_question.option_index)}
        >
          {other_marker(@term.operator_question, @item)} Other · type a custom answer
        </box>
        <box :if={@preview_lines != []} class="px-1 bg-panel border-l border-secondary">
          <box :for={line <- @preview_lines} class="text-muted">{line}</box>
        </box>
      </box>
      <box :if={not is_nil(@item) and @term.operator_question.step == :other} class="w-full">
        <box class="font-bold">{@item.question} · Custom answer</box>
        <.textarea
          id="question-other"
          textarea-value={@answer.other}
          textarea-placeholder="Type the context the agent needs"
          textarea-submit-on-enter={true}
          br-change="question_other_changed"
          br-submit="question_other_submitted"
          class="w-full h-4 border focus:border-primary bg-surface"
        />
      </box>
      <box :if={is_nil(@item)} class="w-full">
        <box class="font-bold">Review answers</box>
        <box :for={row <- @review_rows} class={row.class}>{row.header} · {row.answer}</box>
        <box
          id="question-confirm"
          implicit={Action}
          br-change="question_confirm"
          class="font-bold text-primary focus:bg-primary focus:text-bg"
        >
          {if complete?(@request, @term.operator_question.answers) do
            "Confirm and send"
          else
            "Answer every tab to continue"
          end}
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class={Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="text-muted">{controls(@item, @term.operator_question.step)}</box>
    </box>
    """
  end

  defp reconcile_open(term, pending) do
    current =
      Enum.find(pending, &(&1.id == term.assigns.operator_question.invocation_id))

    cond do
      current &&
          normalize_request(current.coordination.pending_question).id ==
            term.assigns.operator_question.request_id ->
        term

      current ->
        term
        |> activate(current)
        |> Component.assign(notice: Notice.new(:info, "Question changed · answers reset"))

      pending != [] ->
        term
        |> activate(hd(pending))
        |> Component.assign(
          notice: Notice.new(:info, "Question resolved elsewhere · showing next")
        )

      true ->
        close(term, Notice.new(:info, "Question was resolved in another terminal"))
    end
  end

  defp activate(term, invocation) do
    request = normalize_request(invocation.coordination.pending_question)

    current =
      term.assigns.operator_question
      |> store_current_request()
      |> prune_request_state_map(pending_invocations(term))

    request_state = Map.get(current.request_states, request.id, initial_request_state(request))

    next_state =
      current
      |> Map.merge(request_state)
      |> Map.merge(%{invocation_id: invocation.id, request_id: request.id})

    term
    |> SlashPalette.clear()
    |> Component.assign(
      modal: :operator_question,
      operator_question: next_state,
      notice: nil,
      home: false
    )
    |> View.focus("prompt")
  end

  defp initial_request_state(request) do
    first = hd(request.questions)

    %{
      tab_index: 0,
      option_index: recommended_index(first),
      step: :options,
      answers: %{},
      option_indices: %{}
    }
  end

  defp store_current_request(%{request_id: nil} = state), do: state

  defp store_current_request(state) do
    snapshot =
      Map.take(state, [:tab_index, :option_index, :step, :answers, :option_indices])

    %{state | request_states: Map.put(state.request_states, state.request_id, snapshot)}
  end

  defp prune_request_states(term, pending) do
    state = prune_request_state_map(term.assigns.operator_question, pending)
    Component.assign(term, operator_question: state)
  end

  defp prune_request_state_map(state, pending) do
    pending_ids = MapSet.new(pending, & &1.coordination.pending_question.id)
    retained = Map.filter(state.request_states, fn {id, _snapshot} -> id in pending_ids end)
    %{state | request_states: retained}
  end

  defp clear_request_states(term) do
    state = term.assigns.operator_question
    Component.assign(term, operator_question: %{state | request_states: %{}})
  end

  defp enter(term) do
    cond do
      review?(term) ->
        submit_answers(term)

      term.assigns.operator_question.step == :other ->
        finish_other(term)

      current_item(term).multi? ->
        if answer_present?(current_answer(term)),
          do: {:noreply, advance(term)},
          else: {:noreply, warn(term, "Choose at least one answer")}

      true ->
        {:noreply, choose_current(term)}
    end
  end

  defp choose_current(term) do
    if review?(term) do
      term
    else
      item = current_item(term)

      case option_at(item.options, term.assigns.operator_question.option_index) do
        nil when item.allow_other? ->
          term |> clear_single_selection(item) |> put_step(:other)

        nil ->
          term

        option when item.multi? ->
          toggle_option(term, item, option)

        option ->
          term |> put_answer(item.id, [option.id], nil) |> advance()
      end
    end
  end

  defp choose_index(term, index) when is_integer(index) and index >= 0 do
    if review?(term) do
      term
    else
      item = current_item(term)
      max_index = length(item.options) - 1 + if(item.allow_other?, do: 1, else: 0)

      if index <= max_index do
        term
        |> put_option_index(index)
        |> choose_current()
      else
        term
      end
    end
  end

  defp choose_index(term, _index), do: term

  defp toggle_option(term, item, option) do
    answer = current_answer(term)

    option_ids =
      if option.id in answer.option_ids,
        do: List.delete(answer.option_ids, option.id),
        else: answer.option_ids ++ [option.id]

    put_answer(term, item.id, option_ids, answer.other)
  end

  defp clear_single_selection(term, %{multi?: true}), do: term
  defp clear_single_selection(term, item), do: put_answer(term, item.id, [], nil)

  defp move_option(term, offset) do
    if review?(term) do
      term
    else
      count = option_count(current_item(term))

      put_option_index(
        term,
        Integer.mod(term.assigns.operator_question.option_index + offset, count)
      )
    end
  end

  defp put_option_index(term, index) do
    item = current_item(term)
    state = term.assigns.operator_question
    indices = Map.put(state.option_indices, item.id, index)

    Component.assign(term,
      operator_question: %{state | option_index: index, option_indices: indices}
    )
  end

  defp move_tab(term, offset) do
    request = request(term)
    count = length(request.questions) + 1
    put_tab(term, Integer.mod(term.assigns.operator_question.tab_index + offset, count))
  end

  defp put_tab(term, index) when is_integer(index) and index >= 0 do
    request = request(term)

    if index <= length(request.questions) do
      state = term.assigns.operator_question
      item = item_at(request.questions, index)

      option_index =
        if item, do: Map.get(state.option_indices, item.id, recommended_index(item)), else: 0

      term
      |> Component.assign(
        operator_question: %{state | tab_index: index, option_index: option_index, step: :options}
      )
      |> View.focus("prompt")
    else
      term
    end
  end

  defp put_tab(term, _index), do: term

  defp advance(term), do: put_tab(term, term.assigns.operator_question.tab_index + 1)

  defp put_step(term, step) do
    focus = if step == :other, do: "question-other", else: "prompt"
    state = term.assigns.operator_question

    term
    |> Component.assign(operator_question: %{state | step: step})
    |> View.focus(focus)
  end

  defp put_other(term, value) do
    item = current_item(term)
    answer = current_answer(term)
    put_answer(term, item.id, answer.option_ids, value)
  end

  defp finish_other(term) do
    other = term |> current_answer() |> Map.fetch!(:other) |> normalize_other()

    if is_nil(other) do
      {:noreply, warn(term, "Type a custom answer first")}
    else
      item = current_item(term)
      {:noreply, term |> put_answer(item.id, current_answer(term).option_ids, other) |> advance()}
    end
  end

  defp put_answer(term, item_id, option_ids, other) do
    state = term.assigns.operator_question
    answer = %{option_ids: option_ids, other: other || ""}

    Component.assign(term,
      operator_question: %{state | answers: Map.put(state.answers, item_id, answer)}
    )
  end

  defp focus_after_option_click(%{assigns: %{operator_question: %{step: :other}}} = term),
    do: term

  defp focus_after_option_click(term), do: View.focus(term, "prompt")

  defp submit_answers(term) do
    request = request(term)

    if complete?(request, term.assigns.operator_question.answers) do
      answers =
        Enum.map(request.questions, fn item ->
          answer = answer_for(term.assigns.operator_question, item.id)

          %{
            question_id: item.id,
            option_ids: answer.option_ids,
            other: normalize_other(answer.other)
          }
        end)

      case Engine.answer_question(
             term.assigns.operator_question.invocation_id,
             request.id,
             %{answers: answers},
             term.assigns.engine
           ) do
        :ok -> {:noreply, close(term, Notice.new(:success, "Answers sent"))}
        {:error, reason} -> stale_or_error(term, reason, "Could not answer")
      end
    else
      {:noreply, warn(term, "Answer every tab before confirming")}
    end
  end

  defp reject(term) do
    state = term.assigns.operator_question

    case Engine.reject_question(state.invocation_id, state.request_id, term.assigns.engine) do
      :ok -> {:noreply, close(term, Notice.new(:info, "Question rejected"))}
      {:error, reason} -> stale_or_error(term, reason, "Could not reject")
    end
  end

  defp stale_or_error(term, reason, _prefix)
       when reason in [:question_not_found, :stale_question],
       do: {:noreply, close(term, Notice.new(:info, "Question was resolved in another terminal"))}

  defp stale_or_error(term, reason, prefix),
    do: {:noreply, warn(term, "#{prefix}: #{reason}")}

  defp switch_request(term, offset) do
    pending = pending_invocations(term)

    if pending == [] do
      term
    else
      current_index =
        Enum.find_index(pending, &(&1.id == term.assigns.operator_question.invocation_id)) || 0

      switch_request_to(term, Integer.mod(current_index + offset, length(pending)))
    end
  end

  defp switch_request_to(term, index) do
    case item_at(pending_invocations(term), index) do
      nil -> term
      invocation -> activate(term, invocation)
    end
  end

  defp close(term, notice) do
    state = store_current_request(term.assigns.operator_question)
    retained = Map.delete(state.request_states, state.request_id)

    term
    |> Component.assign(
      modal: nil,
      operator_question: %{initial() | request_states: retained},
      notice: notice
    )
    |> View.focus("prompt")
  end

  defp warn(term, message), do: Component.assign(term, notice: Notice.new(:warning, message))

  defp request(term) do
    term.assigns.projection.invocations[term.assigns.operator_question.invocation_id]
    |> Map.fetch!(:coordination)
    |> Map.fetch!(:pending_question)
    |> normalize_request()
  end

  defp current_item(term),
    do: item_at(request(term).questions, term.assigns.operator_question.tab_index)

  defp current_answer(term), do: answer_for(term.assigns.operator_question, current_item(term).id)

  defp review?(term),
    do: term.assigns.operator_question.tab_index == length(request(term).questions)

  defp answer_for(state, item_id),
    do: Map.get(state.answers, item_id, %{option_ids: [], other: ""})

  defp complete?(request, answers) do
    Enum.all?(request.questions, fn item -> answer_present?(Map.get(answers, item.id)) end)
  end

  defp answer_present?(nil), do: false

  defp answer_present?(answer),
    do: answer.option_ids != [] or not is_nil(normalize_other(answer.other))

  defp option_count(item), do: length(item.options) + if(item.allow_other?, do: 1, else: 0)

  defp pending_invocations(term),
    do:
      Projection.pending_question_invocations(
        term.assigns.projection,
        term.assigns.selected_session_id
      )

  defp pending_invocations_from_assigns(term),
    do: Projection.pending_question_invocations(term.projection, term.selected_session_id)

  defp normalize_request(%DurableQuestion{} = request), do: DurableQuestion.from_map(request)

  defp recommended_index(item),
    do: Enum.find_index(item.options, &(&1.id == item.recommended_id)) || 0

  defp item_at(items, index) do
    items
    |> Enum.with_index()
    |> Enum.find_value(fn
      {item, ^index} -> item
      _other -> nil
    end)
  end

  defp option_at(options, index), do: item_at(options, index)

  defp preview_lines(nil, _index), do: []

  defp preview_lines(item, index) do
    case option_at(item.options, index) do
      %{preview: preview} when preview != "" ->
        lines = String.split(preview, "\n")
        {visible, hidden} = Enum.split(lines, @preview_line_count)

        if hidden == [] do
          Enum.map(visible, &truncate_preview_line/1)
        else
          visible
          |> Enum.take(@preview_line_count - 1)
          |> Enum.map(&truncate_preview_line/1)
          |> Kernel.++(["... preview truncated"])
        end

      _other ->
        []
    end
  end

  defp truncate_preview_line(line) do
    if String.length(line) > @preview_line_max_codepoints,
      do: String.slice(line, 0, @preview_line_max_codepoints - 3) <> "...",
      else: line
  end

  defp review_rows(nil, _answers), do: []

  defp review_rows(request, answers) do
    Enum.map(request.questions, fn item ->
      answer = Map.get(answers, item.id)

      %{
        header: item.header,
        answer: answer_label(item, answer),
        class: if(answer_present?(answer), do: "text-primary", else: "text-warning")
      }
    end)
  end

  defp answer_label(_item, nil), do: "Not answered"

  defp answer_label(item, answer) do
    labels =
      item.options
      |> Enum.filter(&(&1.id in answer.option_ids))
      |> Enum.map(& &1.label)

    labels =
      labels ++ if(normalize_other(answer.other), do: [normalize_other(answer.other)], else: [])

    if labels == [], do: "Not answered", else: Enum.join(labels, ", ")
  end

  defp participant_name(nil), do: "Agent"
  defp participant_name(%{participant: %{name: name}}) when is_binary(name), do: name
  defp participant_name(_invocation), do: "Agent"

  defp request_position(pending, invocation_id) do
    index = Enum.find_index(pending, &(&1.id == invocation_id)) || 0
    "#{index + 1}/#{length(pending)}"
  end

  defp tab_class(index, index), do: "pr-2 font-bold text-primary"
  defp tab_class(_index, _selected), do: "pr-2 text-muted"
  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"

  defp answered_marker(answers, item_id),
    do: if(answer_present?(Map.get(answers, item_id)), do: " ✓", else: "")

  defp selection_marker(option, index, state, %{multi?: true}, answer) do
    selected = if option.id in answer.option_ids, do: "x", else: " "
    cursor = if index == state.option_index, do: ">", else: " "
    "#{cursor}[#{selected}]"
  end

  defp selection_marker(_option, index, state, _item, _answer),
    do: if(index == state.option_index, do: ">", else: " ")

  defp other_marker(state, item) do
    cursor = if state.option_index == length(item.options), do: ">", else: " "
    if item.multi?, do: "#{cursor}[ ]", else: cursor
  end

  defp recommended(%{id: id}, %{recommended_id: id}), do: " · recommended"
  defp recommended(_option, _item), do: ""
  defp description(%{description: ""}), do: ""
  defp description(option), do: " · #{option.description}"

  defp controls(nil, _step), do: "Enter confirm · ←→ or Tab review · Esc reject"
  defp controls(_item, :other), do: "Enter keep custom answer · Esc options"

  defp controls(%{multi?: true}, :options),
    do: "1-5 or Space toggle · Enter next · ←→ or Tab · [ ] requests"

  defp controls(_item, :options),
    do: "1-5 or Enter choose · ↑↓ move · ←→ or Tab · [ ] requests"

  defp normalize_other(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp payload_value(payload, key, default),
    do: Map.get(payload, key, Map.get(payload, Atom.to_string(key), default))

  defp parse_index(value) do
    case Integer.parse(value) do
      {index, ""} -> index
      _other -> -1
    end
  end
end
