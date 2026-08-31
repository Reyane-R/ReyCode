defmodule ReyCode.FacadeTest do
  use ExUnit.Case, async: false

  alias ReyCode.Orchestration.{Engine, Squad}
  alias ReyCode.Security.CanonicalPath
  alias ReyCode.Test.Wait

  test "creates blank sessions with an explicit or default workspace" do
    workspace = Path.join(System.tmp_dir!(), "rey_code_facade_#{System.unique_integer()}")
    File.mkdir_p!(workspace)

    assert {:ok, session_id} = ReyCode.create_blank_session("Facade explicit", workspace)
    assert {:ok, canonical} = CanonicalPath.resolve_identity(workspace)
    assert ReyCode.snapshot().sessions[session_id].workspace == canonical

    assert {:ok, default_session_id} = ReyCode.create_blank_session("Facade default workspace")
    assert ReyCode.snapshot().sessions[default_session_id].workspace == File.cwd!()
  end

  test "creates task agents and runs delegated tasks to completion" do
    session_id = fresh_session()

    assert {:ok, participant_id} = ReyCode.create_agent(session_id, "Builder", "implement it")
    assert :ok = ReyCode.configure_participants(session_id, [participant_id], :simulator)

    session = ReyCode.snapshot().sessions[session_id]
    participant = Enum.find(session.participants, &(&1.id == participant_id))
    assert participant.kind == :task
    assert participant.provider == :simulator

    assert {:ok, turn_id} = ReyCode.delegate_task(session_id, participant_id, "Fix the flake")
    turn = Wait.terminal_turn(Engine, turn_id)
    assert turn.outcome == :completed
  end

  test "forwards cancellation, gate, directive, and tool-run decisions to the engine" do
    assert {:error, :turn_not_found} = ReyCode.cancel_turn("turn-missing")
    assert {:error, :turn_not_found} = ReyCode.resolve_gate("turn-missing", nil, :approve)
    assert {:error, :turn_not_found} = ReyCode.direct_squad("turn-missing", "Slow down")

    assert {:error, :invocation_not_found} =
             ReyCode.resolve_tool_run("inv-missing", "run-1", :deny)
  end

  test "configures participant and squad role runtimes" do
    session_id = fresh_session()
    session = ReyCode.snapshot().sessions[session_id]
    primary_id = session.participants |> Enum.find(&(&1.kind == :primary)) |> Map.fetch!(:id)

    assert :ok = ReyCode.configure_participants(session_id, [primary_id], :simulator)
    session = ReyCode.snapshot().sessions[session_id]
    primary = Enum.find(session.participants, &(&1.id == primary_id))
    assert primary.provider == :simulator

    role_ids = Enum.map(Squad.roles(), & &1.id)
    assert :ok = ReyCode.configure_squad_roles(session_id, role_ids, :simulator)
    session = ReyCode.snapshot().sessions[session_id]
    assert session.squad_seats["analyst"].provider == :simulator
  end

  defp fresh_session do
    workspace = Path.join(System.tmp_dir!(), "rey_code_facade_#{System.unique_integer()}")
    File.mkdir_p!(workspace)

    assert {:ok, session_id} = ReyCode.create_blank_session("Facade", workspace)
    session_id
  end
end
