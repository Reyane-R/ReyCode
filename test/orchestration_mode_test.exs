defmodule ReyCode.Orchestration.ModeTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Mode

  describe "closed mode registry" do
    test "IDs and wire values are unique across the registry" do
      modes = Mode.all()

      assert length(modes) == length(Enum.uniq_by(modes, & &1.id))
      assert length(modes) == length(Enum.uniq_by(modes, & &1.wire))
    end

    test "every registered workflow implements the Workflow behaviour" do
      for %{id: id, workflow: workflow} <- Mode.all() do
        assert Code.ensure_loaded(workflow) == {:module, workflow}
        assert function_exported?(workflow, :plan, 3)
        assert function_exported?(workflow, :advance, 3)
        assert function_exported?(workflow, :finalize, 4)
        assert Mode.workflow(id) == workflow
      end
    end

    test "wire values round-trip through decode" do
      for %{id: id, wire: wire, label: label} <- Mode.all() do
        assert {:ok, ^id} = Mode.decode(wire)
        assert Mode.wire(id) == wire
        assert is_binary(label) and label != ""
      end
    end
  end

  describe "boundary rejection" do
    test "unknown wire strings are rejected explicitly" do
      assert {:error, :invalid_mode} = Mode.decode("teleport")
      assert {:error, :invalid_mode} = Mode.decode("")
    end

    test "unknown atoms are rejected instead of surviving to dispatch" do
      assert {:error, :invalid_mode} = Mode.decode(:teleport)

      assert_raise ArgumentError, ~r/unknown orchestration mode/, fn ->
        Mode.workflow(:teleport)
      end
    end

    test "non-atom non-binary values are rejected" do
      assert {:error, :invalid_mode} = Mode.decode(42)
      assert {:error, :invalid_mode} = Mode.decode(nil)
      refute Mode.known?("compare")
    end
  end
end
