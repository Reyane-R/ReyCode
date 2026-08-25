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
  @max_task_participants_per_room 32

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

  @doc "Creates a fresh titled durable session by copying the source workspace and agent profiles."
  @spec create_session(map(), term(), term()) :: response()
  def create_session(state, source_room_id, raw_title) do
    source = state.projection.rooms[source_room_id]

    with :ok <- session_source(source),
         {:ok, title} <- Validation.session_title(raw_title) do
      session_id = Identity.new_id("session")
      slug = Identity.unique_slug(Identity.slugify(title), state.projection)
      participants = Enum.reject(source.participants, &(&1.kind == :legacy))

      entry =
        EventEntries.room_created(
          session_id,
          slug,
          title,
          source.workspace,
          participants
        )

      next = Persistence.append_and_apply!(state, [entry])
      {:reply, {:ok, session_id}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_source(nil), do: {:error, :session_not_found}
  defp session_source(_source), do: :ok

  @doc "Validates and adds one durable task participant to a room."
  @spec add_task_participant(map(), term(), term(), term()) :: response()
  def add_task_participant(state, room_id, raw_name, raw_responsibility) do
    room = state.projection.rooms[room_id]

    cond do
      is_nil(room) ->
        {:reply, {:error, :room_not_found}, state}

      Enum.count(room.participants, &(&1.kind == :task)) >= @max_task_participants_per_room ->
        {:reply, {:error, :participant_limit_reached}, state}

      true ->
        add_valid_task_participant(state, room_id, raw_name, raw_responsibility)
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

  defp add_valid_task_participant(state, room_id, raw_name, raw_responsibility) do
    case Validation.task_participant(raw_name, raw_responsibility) do
      {:ok, name, responsibility} ->
        participant_id = Identity.new_id("participant")

        entry =
          EventEntries.participant_added(
            room_id,
            participant_id,
            name,
            responsibility,
            :task,
            :unconfigured,
            nil
          )

        next = Persistence.append_and_apply!(state, [entry])
        {:reply, {:ok, participant_id}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp apply_configuration({:ok, entries}, state) do
    {:reply, :ok, Persistence.append_and_apply!(state, entries)}
  end

  defp apply_configuration({:error, reason}, state), do: {:reply, {:error, reason}, state}
end
