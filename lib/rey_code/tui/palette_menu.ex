defmodule ReyCode.TUI.PaletteMenu do
  @moduledoc "Goal-oriented discovery over the existing command registry. Groups are navigation, not commands."

  alias ReyCode.Capabilities

  @groups %{
    root: ["/new", "/resume", "/agents", :agents, :review, :settings],
    agents: ["/task", "/agent", "/agents", "/hub", "/plan"],
    review: [
      "/challenge",
      "/runs",
      "/decisions",
      "/advise",
      "/verify",
      "/changes",
      "/artifacts",
      "/context"
    ],
    settings: ["/agents", "/workspace", "/theme", "/tier", "/hotkeys", "/help"]
  }
  @group_labels %{
    root: "← Main menu",
    agents: "Work with task agents…",
    review: "Review work…",
    settings: "Settings…"
  }
  @labels %{
    "/new" => {"New conversation", "new chat start over"},
    "/resume" => {"Resume a conversation", "previous chat continue session"},
    "/agents" =>
      {"Models & participants", "switch model choose model configure provider connect settings"},
    "/model" => {"Select model by name", "model identifier"},
    "/connect" => {"Connect a provider", "api key credentials login"},
    "/agent" => {"Create a task agent", "add participant teammate"},
    "/task" => {"Delegate a task", "delegate work assign task"},
    "/hub" => {"Inspect task agents", "workers background progress"},
    "/plan" => {"Inspect work plan", "planning tasks steps"},
    "/challenge" => {"Challenge an answer", "why evidence assumptions explain decision"},
    "/runs" => {"Inspect execution", "tool history failure logs debug"},
    "/decisions" => {"Inspect decisions", "assumptions rationale memory"},
    "/advise" => {"Request Advisor review", "second opinion review code"},
    "/verify" => {"Verify a change", "check changes test patch"},
    "/changes" => {"Review verified changes", "accept discard patch verification results"},
    "/artifacts" => {"Inspect saved output", "artifacts tool output"},
    "/context" => {"Inspect model context", "summary compaction"},
    "/workspace" => {"Choose workspace", "project folder directory"},
    "/theme" => {"Choose theme", "appearance colors"},
    "/tier" => {"Configure model tiers", "model budget cost"},
    "/hotkeys" => {"Inspect keyboard shortcuts", "keys keybindings"},
    "/help" => {"Help & all commands", "help capabilities"},
    "/export" => {"Export conversation", "save markdown html"},
    "/fork" => {"Fork conversation", "branch conversation"},
    "/history" => {"Search prompt history", "previous prompts"},
    "/home" => {"Session home", "home start screen"},
    "/quit" => {"Quit ReyCode", "exit close application"},
    "/rewind" => {"Rewind conversation", "restore earlier point"},
    "/tree" => {"Inspect session tree", "forks branches sessions"},
    "/cancel" => {"Stop current work", "stop cancel abort"},
    "/steer" => {"Steer current work", "correct instructions redirect"},
    "/retry" => {"Retry failed task", "try again failure"},
    "/tools" => {"Review pending approval", "approve deny permission"},
    "/answer" => {"Answer pending question", "respond decision input"},
    "/dequeue" => {"Restore queued message", "unsend queued follow up"}
  }

  @doc "Enriches commands without changing their identity or execution contract."
  def commands do
    Enum.map(Capabilities.commands(), fn command ->
      {label, keywords} = Map.get(@labels, command.command, {command.description, ""})

      Map.merge(command, %{
        palette_label: label,
        search_terms: [label, keywords],
        search_default?:
          Map.get(command, :argument) != :text or command.command in ["/advise", "/verify"]
      })
    end)
  end

  @doc "Returns a group's entries, optionally prefixed by context-specific commands."
  def entries(group, contextual \\ []) do
    commands = Map.new(commands(), &{&1.command, &1})

    root =
      if "/connect" in contextual, do: List.delete(@groups.root, "/agents"), else: @groups.root

    items = if group == :root, do: contextual ++ root, else: Map.fetch!(@groups, group) ++ [:root]

    items
    |> Enum.uniq()
    |> Enum.with_index()
    |> Enum.map(fn {item, priority} ->
      entry = if is_atom(item), do: group_entry(item), else: Map.fetch!(commands, item)

      entry =
        if group == :root and item == "/agents",
          do: Map.put(entry, :palette_label, "Choose a model"),
          else: entry

      entry
      |> Map.put(:palette_priority, priority)
      |> Map.put(:palette_open?, item != "/steer")
    end)
  end

  defp group_entry(group) do
    %{
      command: "/@#{group}",
      description: "Browse actions",
      action: :palette_group,
      palette_group: group,
      palette_label: Map.fetch!(@group_labels, group)
    }
  end

  def label(%{kind: :command, payload: payload}),
    do: Map.get(payload, :palette_label, payload.command)

  def label(candidate), do: candidate.label

  def detail(%{kind: :command, payload: %{palette_group: _group}}), do: "Enter to browse"

  def detail(%{kind: :command} = candidate),
    do: candidate.insertion <> if(candidate.suffix == "", do: "", else: " …")

  def detail(candidate), do: candidate.detail
end
