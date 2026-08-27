defmodule ReyCode.ProjectInstructionsTest do
  use ExUnit.Case, async: true

  alias ReyCode.ProjectInstructions

  test "loads ancestor AGENTS files and explicitly enabled project skills in stable order" do
    root = temp_root()
    workspace = Path.join(root, "apps/demo")
    File.mkdir_p!(workspace)
    File.write!(Path.join(root, "AGENTS.md"), "root rules")
    File.write!(Path.join(workspace, "AGENTS.md"), "workspace rules")

    skills = Path.join(workspace, ".reycode/skills")
    File.mkdir_p!(Path.join(skills, "release"))
    File.write!(Path.join(skills, "enabled"), "release\n")
    File.write!(Path.join(skills, "release/SKILL.md"), "release procedure")
    on_exit(fn -> File.rm_rf!(root) end)

    capture = ProjectInstructions.capture(workspace)

    assert capture.content =~ "root rules"
    assert capture.content =~ "workspace rules"
    assert capture.content =~ "release procedure"
    assert capture.digest == ReyCode.Hashing.sha256_hex(capture.content)
    assert length(capture.sources) == 3

    assert capture.content =~
             ~r/root rules.*workspace rules.*release procedure/s
  end

  test "surfaces invalid and missing enabled skills as frozen notices" do
    workspace = temp_root()
    skills = Path.join(workspace, ".reycode/skills")
    File.mkdir_p!(skills)
    File.write!(Path.join(skills, "enabled"), "../escape\nmissing\n")
    on_exit(fn -> File.rm_rf!(workspace) end)

    capture = ProjectInstructions.capture(workspace)

    assert capture.content =~ "Rejected invalid project skill name"
    assert capture.content =~ "Configured instruction source is missing"
    assert capture.digest
  end

  test "rejects a skill symlink that leaves the project skills directory" do
    workspace = temp_root()
    outside = temp_root()
    skills = Path.join(workspace, ".reycode/skills")
    File.mkdir_p!(Path.join(skills, "linked"))
    File.write!(Path.join(skills, "enabled"), "linked\n")
    File.write!(Path.join(outside, "SKILL.md"), "outside instructions")
    File.ln_s!(Path.join(outside, "SKILL.md"), Path.join(skills, "linked/SKILL.md"))

    on_exit(fn ->
      File.rm_rf!(workspace)
      File.rm_rf!(outside)
    end)

    capture = ProjectInstructions.capture(workspace)

    refute capture.content =~ "outside instructions"
    assert capture.content =~ "Rejected skill outside project skills directory"
  end

  defp temp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey-code-instructions-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end
end
