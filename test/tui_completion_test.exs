defmodule ReyCode.TUI.CompletionTest do
  use ExUnit.Case, async: true

  alias ReyCode.TUI.Completion

  @commands [
    %{command: "/help", description: "Help", action: :help},
    %{command: "/task", description: "Task", action: :delegation, argument: :participant},
    %{command: "/workspace", description: "Workspace", action: :workspace, argument: :directory}
  ]

  test "ranks and caps candidates deterministically" do
    context = Completion.new(draft: "/", commands: @commands, max_candidates: 2)

    assert Enum.map(Completion.candidates(context), & &1.label) == ["/help", "/task"]
  end

  test "accept replaces only the token at a middle cursor" do
    context = Completion.new(draft: "before /ta after", cursor: 10, commands: @commands)
    candidate = Enum.find(Completion.candidates(context), &(&1.label == "/task"))

    assert {:ok, "before /task  after", 13, "command:/task"} =
             Completion.accept(context, candidate)
  end

  test "parses and revalidates a quoted task Participant name" do
    participant = %{
      id: "participant-1",
      kind: :task,
      name: "Release Agent",
      perspective: "release checks"
    }

    context =
      Completion.new(
        draft: ~s(/task "Release Agent"),
        commands: @commands,
        participants: [participant]
      )

    assert {:ok,
            %{
              command: "/task",
              action: :delegation,
              argument: "participant-1",
              dynamic_id: "participant:participant-1",
              kind: :participant
            }} = Completion.parse(context)

    stale = Completion.new(draft: context.draft, commands: @commands, participants: [])

    assert {:error, :stale_argument} = Completion.parse(stale)
  end

  test "parses free-text steering without treating words as separate command arguments" do
    context =
      Completion.new(
        draft: "/steer use the smaller implementation",
        commands: ReyCode.Capabilities.commands()
      )

    assert {:ok,
            %{
              command: "/steer",
              action: :steer,
              argument: "use the smaller implementation",
              kind: :text
            }} = Completion.parse(context)
  end

  test "directory candidates are immediate, bounded, and workspace-contained" do
    workspace =
      Path.join(System.tmp_dir!(), "rey-code-completion-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, "alpha/nested"))
    File.mkdir_p!(Path.join(workspace, "alpine"))
    File.write!(Path.join(workspace, "also.txt"), "not a directory")
    on_exit(fn -> File.rm_rf!(workspace) end)

    context =
      Completion.new(
        draft: "/workspace al",
        commands: @commands,
        workspace: workspace,
        scan_timeout_ms: 1_000
      )

    assert Enum.map(Completion.candidates(context), & &1.label) == ["alpha/", "alpine/"]
  end
end
