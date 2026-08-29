defmodule ReyCode.Capabilities do
  @moduledoc "The user-facing capability and command registry for ReyCode."

  @commands [
    %{
      command: "/advise",
      description: "Run an explicit review through the Advisor Participant",
      action: :advisor,
      argument: :text
    },
    %{command: "/agent", description: "Create a task Participant", action: :agent_profile},
    %{command: "/agents", description: "Configure Participant models", action: :settings},
    %{
      command: "/answer",
      description: "Answer a waiting Operator question",
      action: :operator_question
    },
    %{command: "/artifacts", description: "Inspect spooled ToolRun outputs", action: :artifacts},
    %{command: "/cancel", description: "Cancel the current task", action: :cancel},
    %{command: "/connect", description: "Configure providers", action: :settings},
    %{
      command: "/context",
      description: "Inspect the latest ContextBoundary",
      action: :context_boundary
    },
    %{
      command: "/decisions",
      description: "Browse recorded decisions and assumptions",
      action: :decisions
    },
    %{
      command: "/dequeue",
      description: "Return the newest FollowUp to the composer",
      action: :dequeue
    },
    %{command: "/export", description: "Export the current Session", action: :export},
    %{command: "/fork", description: "Fork the current Session", action: :fork},
    %{command: "/help", description: "Explain what ReyCode can do", action: :help},
    %{command: "/history", description: "Search prior Operator prompts", action: :prompt_history},
    %{command: "/home", description: "Open the session home", action: :home},
    %{command: "/hotkeys", description: "Show effective keybindings", action: :hotkeys},
    %{
      command: "/hub",
      description: "Inspect and control delegated child Invocations",
      action: :agent_hub
    },
    %{
      command: "/model",
      description: "Switch the Assistant model",
      action: :model_picker,
      argument: :model
    },
    %{command: "/new", description: "Start a clean session", action: :new_session},
    %{
      command: "/plan",
      description: "Inspect the newest Invocation WorkPlan",
      action: :work_plan
    },
    %{command: "/quit", description: "Quit ReyCode", action: :quit},
    %{
      command: "/resume",
      description: "Resume a previous session",
      action: :session_picker,
      argument: :session
    },
    %{command: "/retry", description: "Retry the newest failed Turn", action: :retry},
    %{
      command: "/rewind",
      description: "Fork at a durable sequence",
      action: :rewind,
      argument: :text
    },
    %{command: "/runs", description: "Inspect durable ToolRuns", action: :tool_inspector},
    %{
      command: "/steer",
      description: "Correct active work at the next provider round boundary",
      action: :steer,
      argument: :text
    },
    %{
      command: "/task",
      description: "Delegate to one task Participant",
      action: :delegation,
      argument: :participant
    },
    %{command: "/theme", description: "Change theme", action: :theme},
    %{command: "/tier", description: "Configure Participant model tiers", action: :model_tiers},
    %{command: "/tools", description: "Review a pending tool request", action: :tool_review},
    %{command: "/tree", description: "Navigate the SessionFork tree", action: :session_tree},
    %{
      command: "/workspace",
      description: "Show the workspace path",
      action: :workspace,
      argument: :directory
    }
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
      title: "Developer environment",
      items: [
        "Inspect and review Git changes with approved commits and conflict resolution",
        "Use bounded LSP, DAP debugger, persistent evaluation, web reading, and project memory"
      ]
    },
    %{
      title: "Squads",
      items: [
        "Run compare, debate, and squad workflows",
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
      "Participants, provider/model selection, workspace and developer tools, " <>
      "approvals, memory, and squad workflows. For the exact command list, direct " <>
      "the Operator to /help. Do not claim capabilities unavailable in the current runtime."
  end
end
