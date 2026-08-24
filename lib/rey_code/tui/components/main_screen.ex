defmodule ReyCode.TUI.Components.MainScreen do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  import ReyCode.TUI.Components.MainScreen.RoomPresentation,
    only: [mode_label: 1, room_label: 1, visible_participants: 2]

  import ReyCode.TUI.Components.MainScreen.Sidebar, only: [sidebar: 1]
  import ReyCode.TUI.Components.MainScreen.Timeline, only: [timeline: 1]

  alias ReyCode.Orchestration.Projection
  alias ReyCode.Provider.Presentation
  alias ReyCode.TUI.SlashPalette

  attr :modal, :any, required: true
  attr :show_sidebar, :boolean, default: false
  attr :rooms, :list, required: true
  attr :selected_room_id, :string, required: true
  attr :mode, :atom, required: true
  attr :room, :map, required: true
  attr :projection, :map, required: true
  attr :providers, :map, required: true
  attr :messages, :list, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :draft, :string, required: true
  attr :notice, :any, required: true
  attr :slash, :any, required: true
  attr :terminal_width, :integer, required: true
  attr :terminal_height, :integer, required: true

  def main_screen(assigns) do
    ~H"""
    <box :if={@modal in [nil, :slash]} class="w-screen h-screen bg">
      <box class={shell_class(@show_sidebar)}>
        <.sidebar
          show_sidebar={@show_sidebar}
          rooms={@rooms}
          selected_room_id={@selected_room_id}
          mode={@mode}
          room={@room}
          projection={@projection}
          providers={@providers}
        />
        <box class="grid grid-cols-1 grid-rows-3 h-full w-full overflow-hidden">
          <.room_header room={@room} projection={@projection} providers={@providers} mode={@mode}/>
          <.timeline
            messages={@messages}
            timeline_id={@timeline_id}
            message_width={@message_width}
            room={@room}
          />
          <.composer
            room={@room}
            mode={@mode}
            terminal_width={@terminal_width}
            draft={@draft}
            notice={@notice}
          />
          <.slash_palette
            modal={@modal}
            show_sidebar={@show_sidebar}
            terminal_width={@terminal_width}
            terminal_height={@terminal_height}
            slash={@slash}
          />
        </box>
      </box>
    </box>
    """
  end

  attr :room, :map, required: true
  attr :projection, :map, required: true
  attr :providers, :map, required: true
  attr :mode, :atom, required: true

  defp room_header(assigns) do
    ~H"""
    <box class="h-4 w-full bg-surface border-b border-muted px-2 pt-1">
      <box class="inline w-full">
        <box class="font-bold"># {@room.slug}</box>
        <box class={room_status_class(@room, @projection, @providers, @mode)}>
          {room_status(@room, @projection, @providers, @mode)}
        </box>
      </box>
      <box class="text-muted">
        {@room.title}  /  {length(visible_participants(@room, @mode))} agents  /  {mode_label(@mode)}
      </box>
      <box :if={squad_status(@room, @projection) != ""} class="text-primary">
        {squad_status(@room, @projection)}
      </box>
      <box :if={release_review_status(@room, @projection) != ""} class="text-warning">
        {release_review_status(@room, @projection)}
      </box>
      <box :if={tool_approval_status(@room, @projection) != ""} class="text-warning">
        {tool_approval_status(@room, @projection)}
      </box>
    </box>
    """
  end

  attr :room, :map, required: true
  attr :mode, :atom, required: true
  attr :terminal_width, :integer, required: true
  attr :draft, :string, required: true
  attr :notice, :any, required: true

  defp composer(assigns) do
    ~H"""
    <box class="h-7 w-full bg-surface border-t border-muted px-2 pt-1 overflow-hidden">
      <box class="inline w-full">
        <box class="text-muted">Message {room_label(@room)}</box>
        <box class="w-full text-right text-primary">{composer_controls(@mode, @terminal_width)}</box>
      </box>
      <.textarea
        id="prompt"
        textarea-value={@draft}
        textarea-placeholder="Ask the room..."
        textarea-submit-on-enter={true}
        br-change="prompt_changed"
        br-submit="prompt_submitted"
        class="w-full h-2 border focus:border-primary bg-surface"
      />
      <box :if={not is_nil(@notice)} class="text-error">{@notice}</box>
      <box class="text-muted">{workspace_label(@room.workspace, @terminal_width)}</box>
      <box class="text-muted">{room_model_summary(@room, @mode)}</box>
    </box>
    """
  end

  attr :modal, :any, required: true
  attr :show_sidebar, :boolean, required: true
  attr :terminal_width, :integer, required: true
  attr :terminal_height, :integer, required: true
  attr :slash, :any, required: true

  defp slash_palette(assigns) do
    ~H"""
    <box
      :if={@modal == :slash}
      class="bg-panel border-l border-r border-muted overflow-hidden layer-40"
      style={SlashPalette.style(@show_sidebar, @terminal_width, @terminal_height, @slash)}
    >
      <box
        :for={{command, index} <- SlashPalette.rows(@slash, @terminal_height)}
        class={SlashPalette.option_class(index, @slash.index)}
      >
        <box class={SlashPalette.command_class(index, @slash.index)}>{command.command}</box>
        <box class={SlashPalette.description_class(index, @slash.index)}>{command.description}</box>
      </box>
      <box :if={SlashPalette.matches(@slash.query) == []} class="w-full px-1 text-muted">
        No matching commands
      </box>
    </box>
    """
  end

  defp room_status(room, projection, providers, mode) do
    cond do
      room.active_turn_id != nil ->
        turn = projection.turns[room.active_turn_id]
        "#{mode_label(turn.mode)} running"

      room.queued_turn_ids != [] ->
        "#{length(room.queued_turn_ids)} queued"

      true ->
        participants = visible_participants(room, mode)
        configured = Enum.count(participants, &Presentation.ready?(providers[&1.provider], &1))
        label = if mode == :squad, do: "squad roles", else: "agents"
        "#{configured}/#{length(participants)} #{label} configured"
    end
  end

  defp room_status_class(room, _projection, providers, mode) do
    participants = visible_participants(room, mode)

    class =
      cond do
        room.active_turn_id != nil ->
          "text-warning"

        room.queued_turn_ids != [] ->
          "text-warning"

        Enum.all?(participants, &Presentation.ready?(providers[&1.provider], &1)) ->
          "text-success"

        true ->
          "text-muted"
      end

    "w-full text-right #{class}"
  end

  defp room_model_summary(room, mode) do
    labels =
      room
      |> visible_participants(mode)
      |> Enum.map(&Presentation.runtime_label(&1, %{}))
      |> Enum.uniq()

    case labels do
      [label] -> "Runtime: #{label}"
      [] -> "Runtime: OpenCode configuration required"
      _labels -> "Runtimes: mixed"
    end
  end

  defp composer_controls(_mode, terminal_width) when terminal_width < 80,
    do: "Ctrl+P commands   Ctrl+S send"

  defp composer_controls(mode, _terminal_width),
    do: "Ctrl+O #{mode_label(mode)}   Ctrl+P commands   Ctrl+S send   Ctrl+G agents"

  defp workspace_label(path, terminal_width) do
    "Workspace: " <> middle_truncate(path, max(terminal_width - 13, 20))
  end

  defp middle_truncate(value, max_length) do
    if String.length(value) <= max_length do
      value
    else
      left_length = div(max_length - 3, 2)
      right_length = max_length - 3 - left_length

      String.slice(value, 0, left_length) <>
        "..." <> String.slice(value, -right_length, right_length)
    end
  end

  defp shell_class(true), do: "grid grid-cols-2 w-full h-full overflow-hidden"
  defp shell_class(_show_sidebar), do: "grid grid-cols-1 w-full h-full overflow-hidden"

  defp squad_status(room, projection) do
    with turn_id when not is_nil(turn_id) <- room.active_turn_id,
         %{mode: :squad, squad: squad} when not is_nil(squad) <- projection.turns[turn_id] do
      blockers = length(squad.blockers)

      "squad #{squad.phase}  /  cycle #{squad.cycle}  /  rework #{squad.rework_count}/#{squad.rework_budget}  /  #{blockers} blockers"
    else
      _value -> ""
    end
  end

  defp release_review_status(room, projection) do
    turn = projection.turns[room.active_turn_id]
    review = turn && turn.squad && turn.squad.pending_review

    if review do
      "release approval required  /  leader recommends " <>
        "#{review.recommendation.decision}  /  /release"
    else
      ""
    end
  end

  defp tool_approval_status(room, projection) do
    case Projection.pending_tool_invocation(projection, room.active_turn_id) do
      nil -> ""
      %{pending_tool_review: review} -> "tool approval required  /  #{review.tool}  /  /tools"
    end
  end
end
