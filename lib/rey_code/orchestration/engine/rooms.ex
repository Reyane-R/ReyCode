defmodule ReyCode.Orchestration.Engine.Rooms do
  @moduledoc "Handles room creation and runtime configuration commands for the Engine."

  alias ReyCode.Orchestration.{EventEntries, Validation}

  alias ReyCode.Orchestration.Engine.{
    Configuration,
    Identity,
    Options,
    Persistence
  }

  @type response :: {:reply, term(), map()}

  @doc "Validates and creates one durable room."
  @spec create(map(), term(), term()) :: response()
  def create(state, raw_title, workspace) do
    case Validation.room(raw_title, workspace, config: state.config) do
      {:ok, title, workspace} ->
        room_id = Identity.new_id("room")
        slug = Identity.unique_slug(Identity.slugify(title), state.projection)

        {type, payload, metadata} =
          EventEntries.room_created(
            room_id,
            slug,
            title,
            workspace,
            Options.default_participants(state.config.providers)
          )

        next = Persistence.append_and_apply!(state, [{type, payload, metadata}])
        {:reply, {:ok, room_id}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc "Validates and applies room participant runtime configuration."
  @spec configure_participants(map(), term(), term(), term(), term()) :: response()
  def configure_participants(state, room_id, participant_ids, provider, model) do
    state
    |> Configuration.participants(room_id, participant_ids, provider, model)
    |> apply_configuration(state)
  end

  @doc "Validates and applies squad-role runtime configuration."
  @spec configure_squad_roles(map(), term(), term(), term(), term()) :: response()
  def configure_squad_roles(state, room_id, role_ids, provider, model) do
    state
    |> Configuration.squad_roles(room_id, role_ids, provider, model)
    |> apply_configuration(state)
  end

  defp apply_configuration({:ok, entries}, state) do
    {:reply, :ok, Persistence.append_and_apply!(state, entries)}
  end

  defp apply_configuration({:error, reason}, state), do: {:reply, {:error, reason}, state}
end
