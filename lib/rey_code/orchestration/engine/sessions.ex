defmodule ReyCode.Orchestration.Engine.Sessions do
  @moduledoc "Handles session creation and runtime configuration commands for the Engine."

  alias ReyCode.Orchestration.{EventEntries, ModelTier, Validation}

  alias ReyCode.Orchestration.Engine.{
    Configuration,
    Identity,
    Options,
    Persistence
  }

  @type response :: {:reply, term(), map()}
  @max_task_participants_per_session 32

  @doc "Validates and creates one durable blank session."
  @spec create(map(), term(), term()) :: response()
  def create(state, raw_title, workspace) do
    case Validation.session(raw_title, workspace, config: state.config) do
      {:ok, title, workspace} ->
        session_id = Identity.new_id("session")
        slug = Identity.unique_slug(Identity.slugify(title), state.projection)

        {type, payload, metadata} =
          EventEntries.session_created(
            session_id,
            slug,
            title,
            workspace,
            Options.default_participants(state.config.providers)
          )

        next = Persistence.append_and_apply!(state, [{type, payload, metadata}])
        {:reply, {:ok, session_id}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @doc "Creates a fresh titled durable session by copying the source workspace and agent profiles."
  @spec create_session(map(), term(), term()) :: response()
  def create_session(state, source_session_id, raw_title) do
    source = state.projection.sessions[source_session_id]

    with :ok <- session_source(source),
         {:ok, title} <- Validation.session_title(raw_title) do
      session_id = Identity.new_id("session")
      slug = Identity.unique_slug(Identity.slugify(title), state.projection)
      participants = Enum.reject(source.participants, &(&1.kind == :legacy))

      entry =
        EventEntries.session_created(
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

  @doc "Forks one durable Session at an immutable Projection sequence."
  @spec fork_session(map(), term(), term()) :: response()
  def fork_session(state, source_session_id, through_sequence) do
    source = state.projection.sessions[source_session_id]

    with :ok <- session_source(source),
         :ok <- fork_sequence(through_sequence, state.projection.sequence) do
      session_id = Identity.new_id("session")
      title = source.title <> " (fork)"
      slug = Identity.unique_slug(Identity.slugify(title), state.projection)
      participants = Enum.reject(source.participants, &(&1.kind == :legacy))

      inherited_message_ids =
        Enum.filter(source.message_order, fn message_id ->
          message = state.projection.messages[message_id]

          (message && message.status == :completed) and
            message.created_sequence <= through_sequence
        end)

      entries = [
        EventEntries.session_created(
          session_id,
          slug,
          title,
          source.workspace,
          participants
        ),
        EventEntries.session_forked(
          session_id,
          source,
          through_sequence,
          inherited_message_ids
        )
      ]

      next = Persistence.append_and_apply!(state, entries)
      {:reply, {:ok, session_id}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fork_sequence(sequence, maximum)
       when is_integer(sequence) and sequence >= 0 and sequence <= maximum,
       do: :ok

  defp fork_sequence(_sequence, _maximum), do: {:error, :invalid_fork_sequence}

  defp session_source(nil), do: {:error, :session_not_found}
  defp session_source(_source), do: :ok

  @doc "Validates and adds one durable task participant to a session."
  @spec add_task_participant(map(), term(), term(), term()) :: response()
  def add_task_participant(state, session_id, raw_name, raw_responsibility) do
    session = state.projection.sessions[session_id]

    cond do
      is_nil(session) ->
        {:reply, {:error, :session_not_found}, state}

      Enum.count(session.participants, &(&1.kind == :task)) >= @max_task_participants_per_session ->
        {:reply, {:error, :participant_limit_reached}, state}

      true ->
        add_valid_task_participant(state, session_id, raw_name, raw_responsibility)
    end
  end

  @doc "Validates and applies session participant runtime configuration."
  @spec configure_participants(map(), term(), term(), term(), term()) :: response()
  def configure_participants(state, session_id, participant_ids, provider, model) do
    state
    |> Configuration.participants(session_id, participant_ids, provider, model)
    |> apply_configuration(state)
  end

  @doc "Validates and applies one Participant ModelTier."
  @spec configure_participant_tier(map(), term(), term(), term()) :: response()
  def configure_participant_tier(state, session_id, participant_id, raw_tier) do
    session = state.projection.sessions[session_id]

    with %{} <- session,
         true <- Enum.any?(session.participants, &(&1.id == participant_id)),
         {:ok, tier} <- ModelTier.normalize(raw_tier) do
      entry = EventEntries.participant_tier_configured(session_id, participant_id, tier)
      next = Persistence.append_and_apply!(state, [entry])
      {:reply, :ok, next}
    else
      nil -> {:reply, {:error, :session_not_found}, state}
      false -> {:reply, {:error, :participant_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @doc "Validates and applies squad-role runtime configuration."
  @spec configure_squad_roles(map(), term(), term(), term(), term()) :: response()
  def configure_squad_roles(state, session_id, role_ids, provider, model) do
    state
    |> Configuration.squad_roles(session_id, role_ids, provider, model)
    |> apply_configuration(state)
  end

  defp add_valid_task_participant(state, session_id, raw_name, raw_responsibility) do
    case Validation.task_participant(raw_name, raw_responsibility) do
      {:ok, name, responsibility} ->
        participant_id = Identity.new_id("participant")

        entry =
          EventEntries.participant_added(
            session_id,
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
