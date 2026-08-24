defmodule ReyCode.Orchestration.Engine.ConfigurationTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine.Configuration
  alias ReyCode.RuntimeConfig

  test "plans participant configuration in selected order with duplicate IDs removed" do
    assert {:ok, entries} =
             Configuration.participants(
               state(),
               "room-1",
               ["critic", "builder", "critic"],
               :simulator,
               "ignored"
             )

    assert Enum.map(entries, fn {_type, data, _metadata} -> data["participant_id"] end) == [
             "critic",
             "builder"
           ]

    assert Enum.all?(entries, fn {_type, data, _metadata} ->
             data["provider"] == "simulator" and data["model"] == nil
           end)
  end

  test "plans squad-role events through the same provider and model rules" do
    assert {:ok, [entry]} =
             Configuration.squad_roles(
               state(),
               "room-1",
               "architect",
               :simulator,
               nil
             )

    assert {:squad_role_configured, data, _metadata} = entry
    assert data["role_id"] == "architect"
    assert data["name"] == "Architect"
    assert data["provider"] == "simulator"
  end

  test "preserves target, selection, and provider error precedence for both targets" do
    assert {:error, :room_not_found} =
             Configuration.participants(
               state(%{rooms: %{}}),
               "missing",
               [],
               :unknown,
               nil
             )

    assert {:error, :participant_required} =
             Configuration.squad_roles(
               state(),
               "room-1",
               [],
               :unknown,
               nil
             )

    assert {:error, :participant_not_found} =
             Configuration.participants(
               state(),
               "room-1",
               ["missing"],
               :unknown,
               nil
             )

    assert {:error, :unknown_provider} =
             Configuration.squad_roles(
               state(),
               "room-1",
               ["architect"],
               :unknown,
               nil
             )
  end

  defp state(projection \\ projection()) do
    %{projection: projection, provider_catalog: nil, config: config()}
  end

  defp projection do
    %{
      rooms: %{
        "room-1" => %{
          participants: [
            %{id: "builder"},
            %{id: "critic"},
            %{id: "explorer"}
          ]
        }
      }
    }
  end

  defp config, do: RuntimeConfig.fresh(allow_simulator_provider: true)
end
