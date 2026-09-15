defmodule ReyCode.TUI.Challenge do
  @moduledoc "Select evidence, challenge it with an Advisor, and prepare a cited follow-up."
  use Breeze.Component

  alias BackBreeze.Ucwidth
  alias Breeze.{Component, View}
  alias ReyCode.Memory.Store
  alias ReyCode.Orchestration.{Challenge, Engine}
  alias ReyCode.Provider.TextBuffer
  alias ReyCode.TUI.{Advisor, Notice, SlashPalette, State}

  @max_targets_count 100
  @max_detail_bytes 32_768

  defmodule Choice do
    @moduledoc false
    defstruct [:kind, :id, :label, :data]
  end

  def initial,
    do: %{step: :targets, index: 0, offset: 0, choices: [], target: nil, review_id: nil}

  @doc "Opens a bounded picker of recent answers, recorded decisions, and review evidence."
  def open(term, target \\ nil) do
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]

    cond do
      is_nil(session) ->
        SlashPalette.close(term, Notice.new(:warning, "Open a session before challenging work"))

      session.verified_change != nil ->
        SlashPalette.close(
          term,
          Notice.new(
            :warning,
            "Challenge is available in ordinary sessions; use /changes for verified-change evidence"
          )
        )

      true ->
        {decisions, warning} = decision_choices(term, session)

        state = %{
          initial()
          | choices: answer_choices(term.assigns.projection, session) ++ decisions
        }

        state =
          if target,
            do: %{state | step: :questions, target: target, choices: question_choices()},
            else: state

        term
        |> SlashPalette.clear()
        |> Component.assign(modal: :challenge, challenge: state, notice: warning)
    end
  end

  def focus(term), do: term

  def submit(term) do
    state = term.assigns.challenge
    choice = Enum.at(state.choices, state.index)
    select(term, state.step, choice)
  end

  defp select(term, _step, nil), do: {:noreply, term}
  defp select(term, :targets, %Choice{kind: :review} = choice), do: open_review(term, choice)

  defp select(term, :targets, choice) do
    target = %{"kind" => Atom.to_string(choice.kind), "id" => choice.id}

    {:noreply,
     assign_state(term, %{
       term.assigns.challenge
       | step: :questions,
         index: 0,
         target: target,
         choices: question_choices()
     })}
  end

  defp select(term, :questions, choice), do: queue_review(term, choice.id)

  defp select(term, :sources, %Choice{kind: :experiment} = choice),
    do: prepare_follow_up(term, choice)

  defp select(term, :sources, choice) do
    text =
      "Frozen evidence preview; not a live filesystem inspection.\nMissing/clipped flags and artifact availability are authoritative capture limits.\n\n" <>
        Jason.encode!(choice.data, pretty: true)

    {:noreply,
     assign_state(term, %{term.assigns.challenge | step: :detail, offset: 0, target: text})}
  end

  defp select(term, _step, _choice), do: {:noreply, term}

  def handle_input("Enter", term), do: submit(term)

  def handle_input("Escape", %{assigns: %{challenge: %{step: :detail}}} = term),
    do: {:noreply, assign_state(term, %{term.assigns.challenge | step: :sources, offset: 0})}

  def handle_input("Escape", term), do: {:noreply, close(term)}

  def handle_input(key, term)
      when key in ["ArrowUp", "ArrowDown", "j", "k", "PageUp", "PageDown"] do
    state = term.assigns.challenge
    delta = if key in ["ArrowUp", "k", "PageUp"], do: -1, else: 1

    next =
      if state.step == :detail do
        viewport = viewport(term)
        maximum = max(length(detail_lines(state, viewport)) - visible_count(viewport), 0)
        %{state | offset: min(max(state.offset + delta, 0), maximum)}
      else
        %{state | index: Integer.mod(state.index + delta, max(length(state.choices), 1))}
      end

    {:noreply, assign_state(term, next)}
  end

  def handle_input(_key, term), do: {:noreply, term}
  def handle_event(_event, _payload, _term), do: :unhandled

  defp question_choices do
    Enum.map(Challenge.questions(), fn {id, label} ->
      %Choice{kind: :question, id: id, label: label}
    end)
  end

  defp answer_choices(projection, session) do
    session.message_order
    |> Enum.take(@max_targets_count)
    |> Enum.flat_map(fn id ->
      message = projection.messages[id]
      turn = if message, do: projection.turns[message.turn_id]
      choice_for(message, turn, session.id)
    end)
  end

  defp choice_for(%{role: :assistant, session_id: id} = message, %{status: :terminal} = turn, id) do
    if turn.strategy_review do
      [
        %Choice{
          kind: :review,
          id: turn.id,
          label: "Evidence / follow-up · #{preview(message.body)}",
          data: %{packet: turn.strategy_review, report: message.body}
        }
      ]
    else
      [%Choice{kind: :answer, id: message.id, label: "Answer · #{preview(message.body)}"}]
    end
  end

  defp choice_for(_message, _turn, _session_id), do: []

  defp decision_choices(term, session) do
    case Challenge.memories(session.workspace, Map.get(term.assigns, :memory_store, Store)) do
      {:ok, entries} ->
        {Enum.map(
           entries,
           &%Choice{
             kind: :decision,
             id: &1.id,
             label:
               "#{&1.kind} · #{preview(&1.key)}#{if &1.active, do: "", else: " (invalidated)"}"
           }
         ), nil}

      {:error, reason} ->
        {[], Notice.new(:warning, "Decision evidence unavailable: #{inspect(reason)}")}
    end
  catch
    :exit, _reason ->
      {[], Notice.new(:warning, "Decision evidence unavailable; answers can still be challenged")}
  end

  defp queue_review(term, question) do
    session = term.assigns.projection.sessions[term.assigns.selected_session_id]

    case Advisor.advisor(session) do
      nil ->
        {:noreply,
         Component.assign(term,
           notice:
             Notice.new(:warning, "Create a task Participant named Advisor with /agent first")
         )}

      %{provider: :unconfigured} ->
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:warning, "Configure the Advisor model with /agents")
         )}

      %{model: nil} ->
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:warning, "Configure the Advisor model with /agents")
         )}

      advisor ->
        queue_with_advisor(term, advisor, question)
    end
  end

  defp queue_with_advisor(term, advisor, question) do
    selection = Map.put(term.assigns.challenge.target, "question", question)
    submit = Map.get(term.assigns, :challenge_submit, &Engine.challenge/4)

    case submit.(term.assigns.selected_session_id, advisor.id, selection, term.assigns.engine) do
      {:ok, _id} ->
        {:noreply,
         term
         |> close()
         |> Component.assign(
           notice:
             Notice.new(
               :success,
               "Challenge queued · tool-free review; /challenge to inspect evidence afterward"
             )
         )}

      {:error, reason} ->
        {:noreply,
         Component.assign(term,
           notice: Notice.new(:error, "Could not challenge target: #{inspect(reason)}")
         )}
    end
  end

  defp open_review(term, choice) do
    packet = choice.data.packet

    sources =
      Enum.map(
        Challenge.sources(packet),
        &%Choice{
          kind: :source,
          id: &1["source_id"],
          label: "Evidence #{&1["source_id"]}",
          data: &1
        }
      )

    experiments =
      case Challenge.experiments(packet, choice.data.report) do
        {:ok, entries} ->
          Enum.with_index(entries, 1)
          |> Enum.map(fn {text, index} ->
            %Choice{
              kind: :experiment,
              id: index,
              label: "Prepare follow-up #{index} · #{preview(text)}",
              data: text
            }
          end)

        {:error, _reason} ->
          []
      end

    state = %{
      term.assigns.challenge
      | step: :sources,
        index: 0,
        review_id: choice.id,
        choices: sources ++ experiments
    }

    {:noreply, assign_state(term, state)}
  end

  defp prepare_follow_up(term, choice) do
    id = term.assigns.challenge.review_id

    draft =
      "Follow-up to evidence review #{id}, experiment #{choice.id}:\n#{choice.data}\nReport the observed result and limitations; cite this review ID."

    existing = Map.get(term.assigns.drafts, term.assigns.selected_session_id, "")
    draft = if existing == "", do: draft, else: existing <> "\n\n" <> draft

    next =
      term
      |> close()
      |> State.assign_draft(draft)
      |> Component.assign(
        notice: Notice.new(:info, "Follow-up prepared; review the prompt and send to execute it")
      )

    {:noreply, next}
  end

  defp assign_state(term, state), do: Component.assign(term, challenge: state)
  defp close(term), do: term |> Component.assign(modal: nil, notice: nil) |> View.focus("prompt")

  defp preview(text),
    do:
      text |> TextBuffer.truncate_utf8(240) |> String.replace(~r/\s+/, " ") |> String.slice(0, 80)

  defp visible_count(assigns),
    do: max((get_in(assigns, [:breeze, :terminal, :height]) || 24) - 9, 1)

  defp viewport(%Breeze.Term{terminal: %{size: size}}), do: %{breeze: %{terminal: size}}
  defp viewport(%{assigns: assigns}), do: assigns

  defp detail_lines(state, assigns) do
    width = max((get_in(assigns, [:breeze, :terminal, :width]) || 80) - 6, 1)
    text = TextBuffer.truncate_utf8(state.target, @max_detail_bytes)

    text =
      if byte_size(state.target) > @max_detail_bytes,
        do: text <> "\n[Detail preview clipped at 32768 bytes]",
        else: text

    text |> String.split("\n") |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_line(line, width) do
    {rows, current, _columns} =
      Enum.reduce(String.graphemes(line), {[], [], 0}, fn char, {rows, current, columns} ->
        cells = Ucwidth.width(char)

        if columns + cells > width and current != [] do
          {[Enum.reverse(current) | rows], [char], cells}
        else
          {rows, [char | current], columns + cells}
        end
      end)

    [Enum.reverse(current) | rows] |> Enum.reverse() |> Enum.map(&Enum.join/1)
  end

  attr :term, :map, required: true

  def modal(assigns) do
    state = assigns.term.challenge
    count = visible_count(assigns.term)
    start = max(state.index - count + 1, 0)

    assigns =
      assigns
      |> Map.put(:rows, Enum.with_index(state.choices) |> Enum.slice(start, count))
      |> Map.put(
        :lines,
        if(state.step == :detail,
          do: Enum.slice(detail_lines(state, assigns.term), state.offset, count),
          else: []
        )
      )

    ~H"""
    <box class="w-screen h-screen bg px-2 pt-1 overflow-hidden">
      <box class="h-1 w-full overflow-hidden font-bold text-primary">
        Challenge this · evidence, not assurance
      </box>
      <box class="h-1 w-full overflow-hidden text-muted">
        Select an answer or decision, then a question. Completed reviews expose frozen sources.
      </box>
      <box class="h-1 w-full overflow-hidden text-muted">
        Newest 100 message references and 100 decisions · bounded previews, not a complete audit
      </box>
      <box :if={@term.challenge.step != :detail} class="pt-1">
        <box :if={@rows == []}>No eligible evidence in this session.</box>
        <box
          :for={{row, index} <- @rows}
          class={if index == @term.challenge.index do
      "h-1 w-full overflow-hidden bg-panel text-primary"
    else
      "h-1 w-full overflow-hidden text-muted"
    end}
        >
          {if index == @term.challenge.index do
            "> "
          else
            "  "
          end}{row.label}
        </box>
      </box>
      <box :for={line <- @lines} class="w-full overflow-hidden">{line}</box>
      <box :if={@term.notice} class="text-warning">{@term.notice.message}</box>
      <box class="pt-1 text-muted">
        ↑↓ / j k move · Enter select · Esc back/close · Follow-ups are prepared, never auto-run
      </box>
    </box>
    """
  end
end
