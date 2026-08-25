defmodule ReyCode.Capabilities do
  @moduledoc "The user-facing capability and command registry for ReyCode."

  @commands [
    %{command: "/agent", description: "Create a task Participant", action: :agent_profile},
    %{command: "/agents", description: "Configure Participant models", action: :settings},
    %{command: "/cancel", description: "Cancel the current task", action: :cancel},
    %{command: "/connect", description: "Connect a provider", action: :settings},
    %{command: "/help", description: "Explain what ReyCode can do", action: :help},
    %{command: "/home", description: "Open the session home", action: :home},
    %{command: "/model", description: "Switch the Assistant model", action: :model_picker},
    %{command: "/new", description: "Start a clean session", action: :new_session},
    %{command: "/quit", description: "Quit ReyCode", action: :quit},
    %{command: "/resume", description: "Resume a previous session", action: :session_picker},
    %{command: "/task", description: "Delegate to one task Participant", action: :delegation},
    %{command: "/theme", description: "Change theme", action: :theme},
    %{command: "/tools", description: "Review a pending tool request", action: :tool_review},
    %{command: "/workspace", description: "Show the workspace path", action: :workspace}
  ]

  @sections [
    %{
      title: "Sessions",
      items: [
        "Durable conversations scoped to one workspace",
        "Resume, restart, and inspect messages, rounds, tools, and outcomes"
      ]
    },
    %{
      title: "Participants",
      items: [
        "Use a Primary Participant for ordinary conversation",
        "Create Task Participants and delegate focused work"
      ]
    },
    %{
      title: "Providers",
      items: [
        "Select OpenCode, OMP, or OpenAI-compatible models",
        "Refresh readiness and available models without storing credentials"
      ]
    },
    %{
      title: "Workspace tools",
      items: [
        "Read, edit, write, search, list, and inspect workspace files",
        "Review bounded tool requests before owner-controlled execution"
      ]
    },
    %{
      title: "Squads",
      items: [
        "Run compare, debate, fan-out, and squad workflows",
        "Track roles, retries, artifacts, gates, and rework"
      ]
    }
  ]

  @doc "Returns the sorted slash-command registry used by the command palette."
  @spec commands() :: [map()]
  def commands, do: @commands

  @doc "Returns the deterministic capability sections shown by `/help`."
  @spec sections() :: [map()]
  def sections, do: @sections

  @doc "Returns concise guidance for natural-language capability questions."
  @spec prompt_hint() :: String.t()
  def prompt_hint do
    "If the Operator asks what ReyCode can do, explain its durable sessions, " <>
      "Participants, provider/model selection, workspace tools, approvals, and " <>
      "squad workflows. For the exact command list, direct the Operator to /help. " <>
      "Do not claim capabilities unavailable in the current runtime."
  end
end
