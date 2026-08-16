defmodule ReyCode.Orchestration.Engine.Configuration do
  @moduledoc "Plans validated participant and squad-role runtime configuration events."

  alias ReyCode.Orchestration.{EventEntries, Squad, Validation}
  alias ReyCode.Provider.{Catalog, Registry}

  @type plan_result :: {:ok, [EventEntries.event_entry()]} | {:error, atom()}

  @doc "Validates and plans configuration events for selected room participants."
  @spec participants(map(), term(), term(), term(), term(), GenServer.server()) :: plan_result()
  def participants(projection, room_id, raw_ids, provider, model, provider_catalog) do
    room = projection.rooms[room_id]
    participant_ids = raw_ids |> List.wrap() |> Enum.uniq()
    available_ids = if room, do: Enum.map(room.participants, & &1.id), else: []

    plan(room, participant_ids, available_ids, provider, model, provider_catalog, fn model ->
      EventEntries.participant_configuration(room_id, participant_ids, provider, model)
    end)
  end

  @doc "Validates and plans configuration events for selected squad roles."
  @spec squad_roles(map(), term(), term(), term(), term(), GenServer.server()) :: plan_result()
  def squad_roles(projection, room_id, raw_ids, provider, model, provider_catalog) do
    room = projection.rooms[room_id]
    role_ids = raw_ids |> List.wrap() |> Enum.uniq()
    available_ids = Enum.map(Squad.roles(), & &1.id)

    plan(room, role_ids, available_ids, provider, model, provider_catalog, fn model ->
      EventEntries.squad_role_configuration(room_id, role_ids, provider, model)
    end)
  end

  defp plan(room, ids, available_ids, provider, raw_model, provider_catalog, entries) do
    cond do
      room == nil ->
        {:error, :room_not_found}

      ids == [] ->
        {:error, :participant_required}

      Enum.any?(ids, &(&1 not in available_ids)) ->
        {:error, :participant_not_found}

      not Registry.configurable_provider?(provider) ->
        {:error, :unknown_provider}

      provider == :simulator ->
        {:ok, entries.(nil)}

      true ->
        with {:ok, model} <- Validation.model(raw_model),
             {:ok, _runtime} <- Catalog.resolve(provider, model, provider_catalog) do
          {:ok, entries.(model)}
        end
    end
  end
end
