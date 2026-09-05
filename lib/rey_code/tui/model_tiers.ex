defmodule ReyCode.TUI.ModelTiers do
  @moduledoc "Configures Participant ModelTier metadata and Invocation budgets."

  use Breeze.Component

  alias Breeze.{Component, View}
  alias ReyCode.Orchestration.{Engine, ModelTier}
  alias ReyCode.TUI.{Notice, SlashPalette}

  @spec initial() :: map()
  def initial, do: %{step: :participants, index: 0, participant_id: nil}

  @spec open(map()) :: map()
  def open(term) do
    term
    |> SlashPalette.clear()
    |> Component.assign(modal: :model_tiers, model_tiers: initial(), notice: nil)
  end

  @spec focus(map()) :: map()
  def focus(term), do: term

  @spec submit(map()) :: {:noreply, map()}
  def submit(term), do: {:noreply, confirm(term)}

  @spec handle_input(String.t(), map()) :: {:noreply, map()}
  def handle_input(key, term) when key in ["ArrowUp", "ArrowDown", "j", "k"] do
    offset = if key in ["ArrowUp", "k"], do: -1, else: 1
    count = option_count(term)
    index = Integer.mod(term.assigns.model_tiers.index + offset, count)
    {:noreply, Component.assign(term, model_tiers: %{term.assigns.model_tiers | index: index})}
  end

  def handle_input("Enter", term), do: {:noreply, confirm(term)}
  def handle_input("Escape", term), do: {:noreply, back(term)}
  def handle_input(_key, term), do: {:noreply, term}

  @spec handle_event(term(), map(), map()) :: {:noreply, map()} | :unhandled
  def handle_event(_event, _payload, _term), do: :unhandled

  attr :term, :map, required: true

  def modal(assigns) do
    ~H"""
    <box class="w-screen h-screen bg px-4 pt-3">
      <box class="w-full border-b border-muted pb-1">
        <box class="font-bold text-primary">Model tiers</box>
        <box class="text-muted">Tier freezes the next Invocation token budget.</box>
      </box>
      <box :if={@term.model_tiers.step == :participants} class="pt-3 w-full">
        <box class="font-bold">Choose a Participant</box>
        <box
          :for={{participant, index} <- Enum.with_index(participants(@term))}
          class={row_class(index, @term.model_tiers.index)}
        >
          {marker(index, @term.model_tiers.index)} {participant.name} · {participant.model_tier}
        </box>
      </box>
      <box :if={@term.model_tiers.step == :tiers} class="pt-3 w-full">
        <box class="font-bold">Choose a tier</box>
        <box
          :for={{tier, index} <- Enum.with_index(ModelTier.all())}
          class={row_class(index, @term.model_tiers.index)}
        >
          {marker(index, @term.model_tiers.index)} {tier} · {ModelTier.budget_tokens(tier)} tokens
        </box>
      </box>
      <box :if={not is_nil(@term.notice)} class={"pt-2 " <> Notice.text_class(@term.notice)}>
        {Notice.label(@term.notice)} · {@term.notice.message}
      </box>
      <box class="pt-2 text-muted">Arrow keys or j/k move   Enter select   Esc back</box>
    </box>
    """
  end

  defp confirm(%{assigns: %{model_tiers: %{step: :participants}}} = term) do
    participant = Enum.at(participants(term.assigns), term.assigns.model_tiers.index)

    Component.assign(term,
      model_tiers: %{
        term.assigns.model_tiers
        | step: :tiers,
          index: tier_index(participant.model_tier),
          participant_id: participant.id
      }
    )
  end

  defp confirm(term) do
    tier = Enum.at(ModelTier.all(), term.assigns.model_tiers.index)

    case Engine.configure_participant_tier(
           term.assigns.selected_session_id,
           term.assigns.model_tiers.participant_id,
           tier,
           term.assigns.engine
         ) do
      :ok ->
        close(term, Notice.new(:success, "Model tier set to #{tier}"))

      {:error, reason} ->
        Component.assign(term, notice: Notice.new(:error, "Could not set tier: #{reason}"))
    end
  end

  defp back(%{assigns: %{model_tiers: %{step: :tiers}}} = term),
    do: Component.assign(term, model_tiers: initial())

  defp back(term), do: close(term)

  defp close(term, notice \\ nil) do
    term
    |> Component.assign(modal: nil, model_tiers: initial(), notice: notice)
    |> View.focus("prompt")
  end

  defp participants(term) do
    term.projection.sessions[term.selected_session_id].participants
  end

  defp option_count(%{assigns: %{model_tiers: %{step: :participants}}} = term),
    do: length(participants(term.assigns))

  defp option_count(_term), do: length(ModelTier.all())
  defp tier_index(tier), do: Enum.find_index(ModelTier.all(), &(&1 == tier)) || 0
  defp row_class(index, index), do: "w-full px-1 bg-panel font-bold text-primary"
  defp row_class(_index, _selected), do: "w-full px-1 text-muted"
  defp marker(index, index), do: ">"
  defp marker(_index, _selected), do: " "
end
