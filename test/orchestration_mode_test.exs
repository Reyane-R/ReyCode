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
    # Admission and replay are deliberately different boundaries. Live
    # values (decode/1, known?/1, workflow/1) reject retired IDs so no new
    # turn can enter dispatch; durable values (decode_durable/1) still
    # decode them so historical events keep replaying and rendering.
    # :fan_out is retired — every assertion below pins one side of that
    # split.
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

  describe "retired modes" do
    # The retired :fan_out ID is unknown at every live boundary...
    test "fan_out is invisible to admission and dispatch" do
      refute Mode.known?(:fan_out)
      refute Mode.known?("fan_out")
      assert {:error, :invalid_mode} = Mode.decode("fan_out")
      assert {:error, :invalid_mode} = Mode.decode(:fan_out)

      assert_raise ArgumentError, ~r/unknown orchestration mode/, fn ->
        Mode.workflow(:fan_out)
      end

      assert_raise ArgumentError, ~r/unknown orchestration mode/, fn ->
        Mode.wire(:fan_out)
      end

      refute :fan_out in Mode.ids()
    end

    # ...but decodes inertly at the replay boundary.
    test "fan_out decodes durably for replay and renders a legacy label" do
      assert Mode.decode_durable("fan_out") == {:ok, :fan_out}
      assert Mode.decode_durable(:fan_out) == {:ok, :fan_out}
      assert Mode.label(:fan_out) == "Fan out (legacy)"
      assert "fan_out" in Mode.retired_wire_values()
    end

    test "durable decode stays strict for everything else" do
      assert {:ok, :compare} = Mode.decode_durable("compare")
      assert {:ok, :squad} = Mode.decode_durable(:squad)
      assert {:error, :invalid_mode} = Mode.decode_durable("teleport")
      assert {:error, :invalid_mode} = Mode.decode_durable(:teleport)
      assert {:error, :invalid_mode} = Mode.decode_durable(42)
      assert {:error, :invalid_mode} = Mode.decode_durable(nil)
    end
  end
end
