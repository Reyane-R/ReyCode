defmodule ReyCode.TUI.Components.MainScreen do
  @moduledoc false

  use Breeze.Component
  import Breeze.Blocks

  alias ReyCode.Orchestration.Squad
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

  attr :show_sidebar, :boolean, required: true
  attr :rooms, :list, required: true
  attr :selected_room_id, :string, required: true
  attr :mode, :atom, required: true
  attr :room, :map, required: true
  attr :projection, :map, required: true
  attr :providers, :map, required: true

  defp sidebar(assigns) do
    ~H"""
    <box
      :if={@show_sidebar}
      class="h-full w-30 bg-surface border-r border-muted px-2 pt-1 overflow-hidden"
    >
      <box class="h-4 w-full">
        <box class="font-bold text-primary">REYCODE</box>
        <box class="text-muted">project rooms</box>
      </box>
      <box class="inline pt-1 w-full overflow-hidden">
        <box class="text-muted">ROOMS</box>
        <box class="w-full text-right text-muted">Ctrl+N new</box>
      </box>
      <box id="rooms" focusable class="w-full overflow-hidden pt-1">
        <box :for={item <- @rooms} class={room_class(item.id, @selected_room_id)}>#  {item.slug}</box>
      </box>
      <box class="pt-2 text-muted">{participant_section_label(@mode)}</box>
      <box
        :for={participant <- visible_participants(@room, @mode)}
        class={presence_class(participant, @room, @projection, @providers) <> " w-full overflow-hidden"}
      >
        o  {participant.name}  {Presentation.short_runtime_label(participant)}
      </box>
      <box class="pt-2 px-1 text-muted w-full overflow-hidden">
        o  event log  {@projection.sequence}
      </box>
      <box class="px-1 text-muted w-full overflow-hidden">{Path.basename(@room.workspace)}</box>
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
    </box>
    """
  end

  attr :messages, :list, required: true
  attr :timeline_id, :string, required: true
  attr :message_width, :integer, required: true
  attr :room, :map, required: true

  defp timeline(assigns) do
    ~H"""
    <.scroll
      id={@timeline_id}
      scroll-autoscroll="bottom"
      class="h-full w-full border-none overflow-scroll mute-scrollbar-40 px-2 py-1"
    >
      <box :if={@messages == []} class="pt-4 w-full">
        <box class="font-bold text-primary">Welcome to {room_label(@room)}</box>
        <box class="pt-1 text-muted">
          Send a message, choose an orchestration mode, and let the room respond.
        </box>
      </box>
      <box :for={message <- @messages} class="w-full pb-1 overflow-hidden">
        <box class="inline w-full overflow-hidden">
          <box class={author_badge_class(message)}>{author_badge(message)}</box>
          <box class="font-bold">{message.author.name}</box>
          <box class={message_status_class(message.status)}>{message_status(message.status)}</box>
        </box>
        <box :if={message_metadata(message) != ""} class="pl-3 w-full overflow-hidden text-muted">
          {message_metadata(message)}
        </box>
        <box :if={message.body != ""} class="pl-3 w-full overflow-hidden">
          {render_message(message, @message_width)}
        </box>
        <box
          :if={message.body == "" and message.status in [:queued, :streaming]}
          class="pl-3 w-full text-muted"
        >
          {message_placeholder(message.status)}
        </box>
        <box :if={message.error} class="pl-3 w-full overflow-hidden text-error">
          {error_summary(message.error)}
        </box>
      </box>
    </.scroll>
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

  defp render_message(message, width), do: Breeze.Markdown.render(message.body, width)

  defp message_placeholder(:queued), do: "queued"
  defp message_placeholder(:streaming), do: "thinking..."

  defp message_metadata(%{role: :user, created_at: created_at, turn: turn}) do
    [timestamp(created_at), mode_label(turn.mode)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("  /  ")
  end

  defp message_metadata(%{invocation: invocation}) when not is_nil(invocation) do
    [invocation.label, Presentation.short_runtime_label(invocation.participant)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("  /  ")
  end

  defp message_metadata(_message), do: ""

  defp author_badge(%{role: :user}), do: "[Y]"
  defp author_badge(%{author: %{id: "builder"}}), do: "[B]"
  defp author_badge(%{author: %{id: "critic"}}), do: "[C]"
  defp author_badge(%{author: %{id: "explorer"}}), do: "[E]"
  defp author_badge(_message), do: "[A]"

  defp author_badge_class(%{role: :user}), do: "w-3 font-bold text-secondary"
  defp author_badge_class(%{author: %{id: "builder"}}), do: "w-3 font-bold text-primary"
  defp author_badge_class(%{author: %{id: "critic"}}), do: "w-3 font-bold text-warning"
  defp author_badge_class(_message), do: "w-3 font-bold text-secondary"

  defp message_status(:queued), do: "queued"
  defp message_status(:streaming), do: "typing"
  defp message_status(:failed), do: "failed"
  defp message_status(_status), do: ""

  defp message_status_class(:failed), do: "w-full text-right text-error"

  defp message_status_class(status) when status in [:queued, :streaming],
    do: "w-full text-right text-warning"

  defp message_status_class(_status), do: "w-full text-right text-muted"

  defp room_class(room_id, room_id), do: "w-full px-1 bg-panel font-bold text-primary"
  defp room_class(_room_id, _selected_room_id), do: "w-full px-1 text-muted"

  defp presence_class(participant, room, projection, providers) do
    invocation =
      if room.active_turn_id do
        turn = projection.turns[room.active_turn_id]

        turn.invocation_order
        |> Enum.map(&projection.invocations[&1])
        |> Enum.reverse()
        |> Enum.find(&(&1.participant.id == participant.id))
      end

    case invocation && invocation.status do
      status when status in [:queued, :running] -> "px-1 text-warning"
      :failed -> "px-1 text-error"
      _ -> Presentation.text_class(providers[participant.provider], participant)
    end
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

  defp visible_participants(room, :squad) do
    configured = Map.get(room, :squad_roles, %{})

    Enum.map(Squad.roles(), fn role ->
      Map.get(configured, role.id, %{
        id: role.id,
        name: role.name,
        perspective: role.perspective,
        provider: :unconfigured,
        model: nil
      })
    end)
  end

  defp visible_participants(room, _mode), do: room.participants

  defp participant_section_label(:squad), do: "SQUAD ROLES"
  defp participant_section_label(_mode), do: "AGENTS IN ROOM"

  defp room_label(room), do: "##{room.slug}"

  defp shell_class(true), do: "grid grid-cols-2 w-full h-full overflow-hidden"
  defp shell_class(_show_sidebar), do: "grid grid-cols-1 w-full h-full overflow-hidden"

  defp mode_label(:fan_out), do: "fan-out"
  defp mode_label(mode), do: Atom.to_string(mode)

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
    review = turn && turn.squad && Map.get(turn.squad, :pending_review)

    if review do
      "release approval required  /  leader recommends #{review.decision}  /  /release"
    else
      ""
    end
  end

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%H:%M")
      _ -> ""
    end
  end

  defp error_message(nil), do: nil
  defp error_message(error) when is_map(error), do: error["message"] || error[:message]
  defp error_message(error), do: to_string(error)

  defp error_summary(error) do
    error
    |> error_message()
    |> to_string()
    |> String.split(~r/\R/, trim: true)
    |> List.first()
    |> Kernel.||("Provider invocation failed")
    |> humanize_milliseconds()
    |> truncate(180)
  end

  defp humanize_milliseconds(message) do
    Regex.replace(~r/\b(\d+)ms\b/, message, fn _, milliseconds ->
      milliseconds |> String.to_integer() |> duration_label()
    end)
  end

  defp duration_label(milliseconds) when rem(milliseconds, 60_000) == 0 do
    minutes = div(milliseconds, 60_000)
    "#{minutes} #{if minutes == 1, do: "minute", else: "minutes"}"
  end

  defp duration_label(milliseconds) when rem(milliseconds, 1_000) == 0 do
    seconds = div(milliseconds, 1_000)
    "#{seconds} #{if seconds == 1, do: "second", else: "seconds"}"
  end

  defp duration_label(milliseconds), do: "#{milliseconds} ms"

  defp truncate(value, limit) do
    if String.length(value) <= limit do
      value
    else
      String.slice(value, 0, limit - 1) <> "…"
    end
  end
end
