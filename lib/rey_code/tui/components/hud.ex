defmodule ReyCode.TUI.Components.HUD do
  @moduledoc "Responsive cyberpunk chrome and bounded, truthful Session instrumentation."

  use Breeze.Component

  alias ReyCode.TUI.{Activity, Effects}

  @rail_width_count 30
  @rail_min_width_count 120
  @rail_min_height_count 28
  @max_activity_rows_count 4
  @logo """
  █▀▀▄ █▀▀▀ █   █ ▄▀▀▀ █▀▀█ █▀▀▄ █▀▀▀
  █▄▄▀ █▄▄   ▀█▀  █    █  █ █  █ █▄▄
  █  █ █▄▄▄   █   ▀▄▄▄ █▄▄█ █▄▄▀ █▄▄▄
  """

  @doc "The rail is reserved only when the transcript retains a useful viewport."
  @spec rail_width(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def rail_width(width, height)
      when width >= @rail_min_width_count and height >= @rail_min_height_count,
      do: @rail_width_count

  def rail_width(_width, _height), do: 0

  @doc "Decorative glyphs share the terminal's ASCII policy."
  def glyph(:corner, true), do: "/"
  def glyph(:corner, _ascii), do: "╱"
  def glyph(:vertical, true), do: "|"
  def glyph(:vertical, _ascii), do: "│"
  def glyph(:connection, true), do: "--"
  def glyph(:connection, _ascii), do: "──"

  @doc "Cut-corner terminal frame, with an ASCII rendering for basic terminals."
  def frame(true) do
    BackBreeze.Border.custom(%{
      top: "-",
      bottom: "-",
      left: "|",
      right: "|",
      top_left: "/",
      top_right: "\\",
      bottom_left: "\\",
      bottom_right: "/"
    })
  end

  def frame(_ascii) do
    BackBreeze.Border.custom(%{
      top: "─",
      bottom: "─",
      left: "│",
      right: "│",
      top_left: "╱",
      top_right: "╲",
      bottom_left: "╲",
      bottom_right: "╱"
    })
  end

  attr :width, :integer, required: true
  attr :height, :integer, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, default: false
  attr :skip, :boolean, default: false
  attr :clip, :any, required: true

  def hero(assigns) do
    assigns = Map.put(assigns, :large?, assigns.width >= 72 and assigns.height >= 30)
    assigns = Map.put(assigns, :logo, if(assigns.ascii, do: "R E Y C O D E //", else: @logo))

    ~H"""
    <box :if={@large?} class="pt-1 w-full overflow-hidden">
      <box class="inline w-full">
        <box
          id="hud-logo"
          implicit={Effects}
          effect-kind={:logo}
          effect-enabled={@motion}
          effect-skip={@skip}
          effect-text={@logo}
          effect-clip={@clip}
          class="w-42 h-3 bg text-accent font-bold"
        >
          {@logo}
        </box>
        <box class="pl-3 w-full">
          <box class="text-primary font-bold">TERMINAL // ORCHESTRATION</box>
          <box class="text-muted">Your workspace. Your signal.</box>
          <box class="text-secondary">HUMAN + MACHINE</box>
        </box>
      </box>
      <box class="inline w-full pt-1">
        <box class="text-accent">{glyph(:corner, @ascii)} REYCODE </box>
        <.scan
          id="home-scan"
          width={min(@width - 30, 96)}
          motion={@motion}
          ascii={@ascii}
          clip={@clip}
        />
        <box class="text-muted"> // WORKBENCH</box>
      </box>
    </box>
    """
  end

  attr :id, :string, required: true
  attr :width, :integer, default: 24
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, default: false
  attr :kind, :atom, default: :scanner
  attr :identity, :any, default: nil
  attr :class, :string, default: "bg-surface text-primary"
  attr :clip, :any, default: {0, 0, 0, 0}

  def scan(assigns) do
    ~H"""
    <box
      id={@id}
      implicit={Effects}
      effect-kind={@kind}
      effect-enabled={@motion}
      effect-ascii={@ascii}
      effect-width={@width}
      effect-identity={@identity}
      effect-clip={@clip}
      class={"h-1 bg-surface overflow-hidden " <> @class}
      style={%{width: max(@width, 1)}}
    >
    </box>
    """
  end

  attr :session, :map, required: true
  attr :motion, :boolean, default: false
  attr :ascii, :boolean, default: false
  attr :clip, :any, required: true

  def home_rail(assigns) do
    ~H"""
    <box class="w-30 h-full bg-surface border-l border-accent px-2 overflow-hidden">
      <box class="pt-1 font-bold text-accent">{glyph(:corner, @ascii)} NEURAL INTERFACE</box>
      <box class="text-muted">REYCODE // LOCAL TERMINAL</box>
      <box
        id="home-emblem"
        implicit={Effects}
        effect-kind={:emblem}
        effect-enabled={@motion}
        effect-ascii={@ascii}
        effect-clip={@clip}
        class="mt-1 h-7 w-24 bg-surface text-primary"
      >
      </box>
      <.scan
        id="home-carrier"
        width={24}
        kind={:signal}
        motion={@motion}
        ascii={@ascii}
        class="text-secondary"
        clip={@clip}
      />
      <box class="pt-1 text-muted">// WORKSPACE LINK</box>
      <box class="font-bold">{Path.basename(@session.workspace)}</box>
      <box class="pt-1 text-primary">[ YOU ]</box>
      <box class="text-accent">    {glyph(:vertical, @ascii)}</box>
      <box class="text-primary">[ ASSISTANT ]</box>
      <box class="text-muted">    {glyph(:vertical, @ascii)}</box>
      <box class="text-secondary">[ TOOLS + TEAMMATES ]</box>
      <box class="pt-1 text-muted">// COMMAND DECK</box>
      <box class="text-primary">/agent   Create teammate</box>
      <box class="text-primary">/task    Delegate work</box>
      <box class="text-primary">/resume  Session archive</box>
      <box class="pt-1 text-muted">HUMAN INTENT. MACHINE SPEED.</box>
    </box>
    """
  end

  attr :session, :map, required: true
  attr :activity, :map, required: true
  attr :token_label, :string, required: true
  attr :motion, :boolean, required: true
  attr :ascii, :boolean, required: true
  attr :clip, :any, required: true

  def rail(assigns) do
    height = elem(assigns.clip, 3) - elem(assigns.clip, 1)
    limit = min(@max_activity_rows_count, max(div(height - 17, 3), 0))

    items =
      assigns.activity.ordered_invocation_ids
      |> Enum.map(&Activity.invocation(assigns.activity, &1))
      |> Enum.take(limit)

    assigns = Map.put(assigns, :items, items)

    ~H"""
    <box class="w-30 h-full border-l border-accent bg-surface px-1 overflow-hidden">
      <box class="text-accent font-bold">{glyph(:corner, @ascii)} SESSION // HUD</box>
      <.scan
        id="rail-scan"
        width={26}
        motion={@motion == true and @activity.active?}
        ascii={@ascii}
        clip={@clip}
      />
      <box class="pt-1 text-muted">01 / ACTIVITY</box>
      <box class={"font-bold text-" <> Activity.color(@activity.header)}>
        {if @activity.header do
          @activity.header.label
        else
          "Idle"
        end}
      </box>
      <box class="pt-1 text-muted">02 / REPORTED USAGE</box>
      <box class="h-2 overflow-hidden text-primary">{@token_label}</box>
      <box class="pt-1 text-muted">03 / WORKSPACE</box>
      <box class="h-1 overflow-hidden">{Path.basename(@session.workspace)}</box>
      <box class="pt-1 text-muted">04 / EXECUTION LINKS</box>
      <box class="text-primary">[ YOU ] {glyph(:connection, @ascii)} [ ASSISTANT ]</box>
      <box :if={@activity.ordered_invocation_ids == []} class="text-muted">No invocations yet</box>
      <box :for={item <- @items} class="pt-1">
        <box class="inline">
          <.scan
            id={"link-" <> item.id}
            kind={:link}
            width={8}
            motion={@motion == true and item.active?}
            ascii={@ascii}
            class={"text-" <> Activity.color(item)}
            clip={@clip}
          />
          <box class="pl-1">{item.label}</box>
        </box>
        <box class="text-muted overflow-hidden">{item.target}</box>
      </box>
      <box :if={length(@activity.ordered_invocation_ids) > length(@items)} class="text-secondary">
        More in /hub · /runs
      </box>
    </box>
    """
  end

  attr :term, :map, required: true

  def modal_chrome(assigns) do
    assigns =
      Map.put(assigns, :term, Map.get(assigns, :term) || assigns.__breeze_caller_assigns__)

    ~H"""
    <box
      :if={@term.modal not in [nil, :slash, :operator_question]}
      class="h-1 bg-surface text-accent overflow-hidden"
      style={%{position: :fixed, top: 0, left: 0, width: @term.breeze.terminal.width, layer: 60}}
    >
      <box class="inline w-full">
        <box class="font-bold">{glyph(:corner, @term.animation_style == :ascii)} REYCODE // </box>
        <.scan
          id="modal-scan"
          width={min(max(@term.breeze.terminal.width - 14, 1), 96)}
          identity={@term.modal}
          motion={not @term.config.tui.reduced_motion?}
          ascii={@term.animation_style == :ascii}
          class="text-accent"
          clip={{0, 0, @term.breeze.terminal.width, 1}}
        />
      </box>
    </box>
    """
  end
end
