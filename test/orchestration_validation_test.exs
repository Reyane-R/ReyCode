defmodule ReyCode.Orchestration.ValidationTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Validation
  alias ReyCode.Security.CanonicalPath

  test "normalizes valid command values" do
    workspace = temporary_directory("valid")
    on_exit(fn -> File.rm_rf(workspace) end)

    assert {:ok, "Room", canonical} = Validation.room("  Room  ", workspace)
    assert {:ok, ^canonical} = CanonicalPath.resolve(workspace)
    assert {:ok, "message"} = Validation.message("  message  ")
    assert {:ok, "openai/gpt-5"} = Validation.model(" openai/gpt-5 ")
  end

  test "rejects malformed values without raising" do
    assert {:error, :invalid_title} = Validation.room(nil, "/tmp")
    assert {:error, :empty_title} = Validation.room("  ", "/tmp")
    assert {:error, :invalid_workspace} = Validation.room("Room", nil)
    assert {:error, :invalid_message} = Validation.message(%{})
    assert {:error, :model_required} = Validation.model(" ")
  end

  test "requires an existing directory and rejects root and NUL" do
    file = Path.join(System.tmp_dir!(), "rey_code_file_#{System.unique_integer([:positive])}")
    File.write!(file, "not a directory")
    on_exit(fn -> File.rm(file) end)

    assert {:error, :invalid_workspace} = Validation.room("Room", file)
    assert {:error, :invalid_workspace} = Validation.room("Room", file <> "-missing")
    assert {:error, :invalid_workspace} = Validation.room("Room", "/")
    assert {:error, :invalid_workspace} = Validation.room("Room", "bad" <> <<0>> <> "path")
  end

  test "resolves workspace symlinks and enforces injectable policy roots" do
    root = temporary_directory("root")
    workspace = Path.join(root, "workspace")
    link = Path.join(System.tmp_dir!(), "rey_code_link_#{System.unique_integer([:positive])}")
    outside = temporary_directory("outside")

    File.mkdir!(workspace)
    File.ln_s!(workspace, link)

    on_exit(fn ->
      File.rm(link)
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    assert {:ok, "Room", canonical} = Validation.room("Room", link, roots: [root])
    assert {:ok, ^canonical} = CanonicalPath.resolve(workspace)

    assert {:error, :invalid_workspace} =
             Validation.room("Room", outside, roots: [root])
  end

  describe "cancellation/2" do
    test "normalizes valid reasons and accepts already finished turns first" do
      assert {:ok, "User stopped it"} =
               Validation.cancellation(%{status: :running}, "  User stopped it  ")

      assert {:ok, :already_finished} = Validation.cancellation(%{status: :completed}, nil)
    end

    test "preserves turn and reason error precedence" do
      assert {:error, :turn_not_found} = Validation.cancellation(nil, nil)

      assert {:error, :invalid_cancellation_reason} =
               Validation.cancellation(%{status: :running}, nil)

      assert {:error, :invalid_cancellation_reason} =
               Validation.cancellation(%{status: :running}, "bad" <> <<0>> <> "reason")

      assert {:error, :invalid_cancellation_reason} =
               Validation.cancellation(%{status: :running}, String.duplicate("x", 1_001))
    end
  end

  describe "squad_directive/2" do
    test "checks turn readiness before normalizing the directive" do
      assert {:error, :turn_not_found} = Validation.squad_directive(nil, "")

      assert {:error, :not_a_squad_turn} =
               Validation.squad_directive(%{mode: :compare, status: :running}, "")

      assert {:error, :squad_not_running} =
               Validation.squad_directive(%{mode: :squad, status: :completed}, "")

      assert {:error, :squad_not_running} =
               Validation.squad_directive(%{mode: :squad, status: :running, squad: nil}, "")

      assert {:error, :empty_directive} =
               Validation.squad_directive(running_squad(), "   ")

      assert {:ok, "Keep it small"} =
               Validation.squad_directive(running_squad(), "  Keep it small  ")
    end
  end

  describe "gate_resolution/4" do
    test "normalizes decisions, targets, and reasons" do
      review = running_squad().squad.pending_review

      assert {:ok, ^review, :rework, "stories", ["Missing tests"]} =
               Validation.gate_resolution(
                 running_squad(),
                 "rework",
                 "stories",
                 ["  Missing tests  ", "  "]
               )

      assert {:ok, ^review, :approve, nil, []} =
               Validation.gate_resolution(running_squad(), :approve, "", [])
    end

    test "preserves precondition and field error precedence" do
      assert {:error, :turn_not_found} = Validation.gate_resolution(nil, :ship, :bad, :bad)

      assert {:error, :not_a_squad_turn} =
               Validation.gate_resolution(%{mode: :compare}, :ship, :bad, :bad)

      assert {:error, :squad_not_running} =
               Validation.gate_resolution(%{mode: :squad, status: :completed}, :ship, :bad, :bad)

      assert {:error, :gate_review_not_pending} =
               Validation.gate_resolution(
                 %{mode: :squad, status: :running, squad: %{pending_review: nil}},
                 :ship,
                 :bad,
                 :bad
               )

      assert {:error, :invalid_gate_decision} =
               Validation.gate_resolution(running_squad(), :ship, :bad, :bad)

      assert {:error, :invalid_rework_target} =
               Validation.gate_resolution(running_squad(), :approve, "stories", :bad)

      assert {:error, :invalid_gate_reasons} =
               Validation.gate_resolution(running_squad(), :approve, nil, :bad)
    end
  end

  defp temporary_directory(label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "rey_code_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp running_squad do
    %{
      mode: :squad,
      status: :running,
      squad: %{pending_review: %{phase: "release_gate", cycle: 1}}
    }
  end
end
