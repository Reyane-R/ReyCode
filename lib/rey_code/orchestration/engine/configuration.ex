defmodule ReyCode.Orchestration.Engine.Configuration do
  @moduledoc "Plans validated participant and squad-role runtime configuration events."

  alias ReyCode.Orchestration.{EventEntries, Squad, Validation}
  alias ReyCode.Provider.{Catalog, Registry}

  @type plan_result :: {:ok, [EventEntries.event_entry()]} | {:error, atom()}

  @doc "Validates and plans configuration events for selected session participants."
  @spec participants(map(), term(), term(), atom(), term()) :: plan_result()
  def participants(state, session_id, raw_ids, provider, model) do
    session = state.projection.sessions[session_id]
    participant_ids = raw_ids |> List.wrap() |> Enum.uniq()
    available_ids = if session, do: Enum.map(session.participants, & &1.id), else: []

    with :ok <- validate_selection(session, participant_ids, available_ids),
         {:ok, model} <- resolve_model(state, provider, model) do
      {:ok, EventEntries.participant_configuration(session_id, participant_ids, provider, model)}
    end
  end

  @doc "Validates and plans configuration events for selected squad roles."
  @spec squad_roles(map(), term(), term(), atom(), term()) :: plan_result()
  def squad_roles(state, session_id, raw_ids, provider, model) do
    role_ids = raw_ids |> List.wrap() |> Enum.uniq()

    with :ok <-
           validate_selection(
             state.projection.sessions[session_id],
             role_ids,
             Enum.map(Squad.roles(), & &1.id)
           ),
         {:ok, model} <- resolve_model(state, provider, model) do
      {:ok, EventEntries.squad_role_configuration(session_id, role_ids, provider, model)}
    end
  end

  # Error precedence is part of the contract: target session, then selection
  # shape, then membership, then provider configuration, then model/runtime.
  defp validate_selection(session, ids, available_ids) do
    cond do
      session == nil ->
        {:error, :session_not_found}

      ids == [] ->
        {:error, :participant_required}

      Enum.any?(ids, &(&1 not in available_ids)) ->
        {:error, :participant_not_found}

      true ->
        :ok
    end
  end

  defp resolve_model(state, provider, raw_model) do
    with :ok <- configurable?(state, provider) do
      model_for(state, provider, raw_model)
    end
  end

  defp configurable?(state, provider) do
    if Registry.configurable_provider?(provider, config: state.config),
      do: :ok,
      else: {:error, :unknown_provider}
  end

  # The simulator is its own runtime: it needs no model or catalog entry.
  defp model_for(_state, :simulator, _raw_model), do: {:ok, nil}

  defp model_for(state, provider, raw_model) do
    with {:ok, model} <- Validation.model(raw_model),
         {:ok, _runtime} <- Catalog.resolve(provider, model, state.provider_catalog) do
      {:ok, model}
    end
  end
end
