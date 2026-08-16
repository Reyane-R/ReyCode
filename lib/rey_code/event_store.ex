defmodule ReyCode.EventStore do
  @moduledoc "A single-writer transactional event store with SQLite and legacy NDJSON backends."

  use GenServer

  alias ReyCode.Event
  alias ReyCode.EventStore.Record
  alias ReyCode.EventStore.SQLite
  alias ReyCode.Security.CanonicalPath

  require Logger

  @type option ::
          {:name, GenServer.name() | nil}
          | {:path, Path.t()}
          | {:backend, :ndjson | :sqlite}
          | {:legacy_path, Path.t()}
  @type entry :: {Event.type(), map(), keyword()}

  @doc "Starts the single-writer event store for the configured backend and path."
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Loads all durable events in global sequence order."
  @spec load(GenServer.server()) :: [Event.t()]
  def load(server \\ __MODULE__), do: GenServer.call(server, :load, :infinity)

  @doc "Loads the latest projection checkpoint and the events needed to resume replay."
  @spec load_projection(GenServer.server()) :: {:ok, map() | nil, [Event.t()]} | {:error, term()}
  def load_projection(server \\ __MODULE__) do
    GenServer.call(server, :load_projection, :infinity)
  end

  @doc "Persists a projection checkpoint when the backend supports checkpoints."
  @spec checkpoint(map(), GenServer.server()) :: :ok | {:error, term()}
  def checkpoint(projection, server \\ __MODULE__) do
    GenServer.call(server, {:checkpoint, projection}, :infinity)
  end

  @doc "Appends one durable event and returns its assigned event record."
  @spec append(Event.type(), map(), GenServer.server(), keyword()) ::
          {:ok, Event.t()} | {:error, term()}
  def append(type, data, server \\ __MODULE__, metadata \\ []) do
    case append_many([{type, data, metadata}], server) do
      {:ok, [event]} -> {:ok, event}
      {:error, _reason} = error -> error
    end
  end

  @doc "Atomically appends a batch, optionally enforcing an expected global sequence."
  @spec append_many([entry()], GenServer.server(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def append_many(entries, server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:append_many, entries, opts}, :infinity)
  end

  @doc "Checks the store's integrity and returns backend verification details."
  @spec verify(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def verify(server \\ __MODULE__), do: GenServer.call(server, :verify, :infinity)

  @doc "Creates a consistent backup at a destination that must not already exist."
  @spec backup(Path.t(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def backup(destination, server \\ __MODULE__) do
    GenServer.call(server, {:backup, destination}, :infinity)
  end

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:path) |> Path.expand()

    case CanonicalPath.resolve_identity(path) do
      {:ok, canonical_path} ->
        ownership_key = {__MODULE__, canonical_path}
        backend = Keyword.get(opts, :backend, backend_for(path))

        case :global.register_name(ownership_key, self()) do
          :yes ->
            init_backend(backend, path, ownership_key, opts)

          :no ->
            {:stop, {:already_started, :global.whereis_name(ownership_key)}}
        end

      {:error, reason} ->
        {:stop, {:ownership_path_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:load, _from, %{backend: :sqlite} = state) do
    {:reply, SQLite.load(state), state}
  end

  def handle_call(:load, _from, state) do
    {:reply, read_events(state.path) |> elem(0), state}
  end

  def handle_call(:load_projection, _from, %{backend: :sqlite} = state) do
    limit = Application.get_env(:rey_code, :max_replay_events, 2_000)
    max_checkpoint_bytes = Application.get_env(:rey_code, :max_checkpoint_bytes, 67_108_864)
    {:reply, SQLite.load_projection(state, limit, max_checkpoint_bytes), state}
  end

  def handle_call(:load_projection, _from, state) do
    {:reply, {:ok, nil, read_events(state.path) |> elem(0)}, state}
  end

  def handle_call({:checkpoint, projection}, _from, %{backend: :sqlite} = state) do
    max_bytes = Application.get_env(:rey_code, :max_checkpoint_bytes, 67_108_864)
    {:reply, SQLite.checkpoint(state, projection, max_bytes), state}
  end

  def handle_call({:checkpoint, _projection}, _from, state), do: {:reply, :ok, state}

  def handle_call({:append_many, [], _opts}, _from, state), do: {:reply, {:ok, []}, state}

  def handle_call({:append_many, entries, opts}, _from, %{backend: :sqlite} = state) do
    case SQLite.append_many(state, entries, opts) do
      {:ok, events, next} -> {:reply, {:ok, events}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:append_many, entries, opts}, _from, state) do
    expected_sequence = Keyword.get(opts, :expected_sequence, state.sequence)

    if expected_sequence != state.sequence do
      {:reply, {:error, {:conflict, state.sequence}}, state}
    else
      append_ndjson(entries, state)
    end
  end

  def handle_call(:verify, _from, %{backend: :sqlite} = state) do
    {:reply, SQLite.verify(state), state}
  end

  def handle_call(:verify, _from, state) do
    {events, sequence} = read_events(state.path)

    {:reply,
     {:ok, %{backend: :ndjson, path: state.path, sequence: sequence, events: length(events)}},
     state}
  end

  def handle_call({:backup, destination}, _from, %{backend: :sqlite} = state) do
    {:reply, SQLite.backup(state, destination), state}
  end

  def handle_call({:backup, destination}, _from, state) do
    destination = Path.expand(destination)

    reply =
      if File.exists?(destination) do
        {:error, :destination_exists}
      else
        with :ok <- File.mkdir_p(Path.dirname(destination)),
             {:ok, _bytes} <- File.copy(state.path, destination),
             :ok <- File.chmod(destination, 0o600) do
          {:ok, %{backend: :ndjson, path: destination, sequence: state.sequence}}
        end
      end

    {:reply, reply, state}
  end

  defp append_ndjson(entries, state) do
    events =
      entries
      |> Enum.with_index(state.sequence + 1)
      |> Enum.map(fn {{type, data, metadata}, sequence} ->
        Event.new(sequence, type, data, metadata)
      end)

    payload = Record.encode!(events) <> "\n"

    {:ok, :ok} =
      File.open(state.path, [:append, :binary], fn file ->
        :ok = IO.binwrite(file, payload)
        :file.sync(file)
      end)

    next = %{state | sequence: state.sequence + length(events)}
    {:reply, {:ok, events}, next}
  end

  @impl true
  def terminate(_reason, %{backend: :sqlite} = state) do
    _ = SQLite.close(state)
    release_ownership(state.ownership_key)
    :ok
  end

  def terminate(_reason, %{ownership_key: ownership_key}) do
    release_ownership(ownership_key)
    :ok
  end

  defp release_ownership(ownership_key) do
    if :global.whereis_name(ownership_key) == self() do
      :global.unregister_name(ownership_key)
    end
  end

  defp backend_for(path) do
    if Path.extname(path) in [".db", ".sqlite", ".sqlite3"], do: :sqlite, else: :ndjson
  end

  defp init_backend(:ndjson, path, ownership_key, _opts) do
    :ok = path |> Path.dirname() |> File.mkdir_p()
    {_events, last_sequence} = read_events(path)
    normalize_tail!(path)

    {:ok,
     %{
       backend: :ndjson,
       path: path,
       ownership_key: ownership_key,
       sequence: last_sequence
     }}
  end

  defp init_backend(:sqlite, path, ownership_key, opts) do
    case SQLite.open(path) do
      {:ok, state} ->
        case maybe_import_legacy(state, opts[:legacy_path]) do
          {:ok, state} ->
            {:ok, Map.put(state, :ownership_key, ownership_key)}

          {:error, reason} ->
            _ = SQLite.close(state)
            release_ownership(ownership_key)
            {:stop, reason}
        end

      {:error, reason} ->
        release_ownership(ownership_key)
        {:stop, reason}
    end
  end

  defp init_backend(backend, _path, ownership_key, _opts) do
    release_ownership(ownership_key)
    {:stop, {:unsupported_event_store_backend, backend}}
  end

  defp maybe_import_legacy(%{sequence: sequence} = state, _legacy_path) when sequence > 0,
    do: {:ok, state}

  defp maybe_import_legacy(state, nil), do: {:ok, state}

  defp maybe_import_legacy(state, legacy_path) do
    legacy_path = Path.expand(legacy_path)

    if File.exists?(legacy_path) do
      backup_path = legacy_path <> ".pre-sqlite-backup"

      with :ok <- preserve_legacy(legacy_path, backup_path),
           {events, _sequence} <- read_events(legacy_path),
           {:ok, next} <- SQLite.import_events(state, events),
           true <- SQLite.load(next) == events do
        {:ok, next}
      else
        false -> {:error, :legacy_import_projection_mismatch}
        {:error, reason} -> {:error, {:legacy_import_failed, reason}}
      end
    else
      {:ok, state}
    end
  end

  defp preserve_legacy(source, destination) do
    if File.exists?(destination) do
      :ok
    else
      case File.copy(source, destination) do
        {:ok, _bytes} -> File.chmod(destination, 0o600)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp read_events(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {events, tail, tail_offset} = read_records(file)

          events =
            case {tail, Jason.decode(tail)} do
              {"", _result} ->
                events

              {_tail, {:ok, value}} ->
                events ++ Record.decode_value!(value)

              {_tail, {:error, _reason}} ->
                truncate_torn_tail!(path, tail_offset, byte_size(tail))
                events
            end

          validate_sequence!(events)
          {events, last_sequence(events)}
        after
          File.close(file)
        end

      {:error, :enoent} ->
        {[], 0}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read event log", path: path
    end
  end

  defp read_records(file) do
    {events, tail, tail_offset} =
      file
      |> IO.binstream(:line)
      |> Enum.reduce({[], "", 0}, fn raw_line, {acc, tail, offset} ->
        if String.ends_with?(raw_line, "\n") do
          {keep_line(acc, String.trim_trailing(raw_line, "\n")), tail,
           offset + byte_size(raw_line)}
        else
          {acc, String.trim_trailing(raw_line, "\n"), offset}
        end
      end)

    {Enum.reverse(events), tail, tail_offset}
  end

  defp keep_line(acc, ""), do: acc

  defp keep_line(acc, line) do
    batch = Record.decode!(line)

    if Enum.any?(batch, &(&1.type == :snapshot_recorded)) do
      Enum.reverse(batch)
    else
      Enum.reverse(batch) ++ acc
    end
  end

  defp last_sequence(events) do
    case List.last(events) do
      nil -> 0
      event -> event.sequence
    end
  end

  defp normalize_tail!(path) do
    case File.open(path, [:read, :write, :binary]) do
      {:ok, file} ->
        try do
          {:ok, eof_size} = :file.position(file, :eof)

          if eof_size > 0 do
            {:ok, _position} = :file.position(file, eof_size - 1)
            {:ok, last_byte} = :file.read(file, 1)

            if last_byte != "\n" do
              :ok = IO.binwrite(file, "\n")
              :file.sync(file)
              Logger.info("normalized event log tail path=#{path}")
            end
          end
        after
          File.close(file)
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "normalize event log", path: path
    end
  end

  defp truncate_torn_tail!(path, offset, removed_bytes) do
    {:ok, :ok} =
      File.open(path, [:read, :write, :binary], fn file ->
        {:ok, ^offset} = :file.position(file, offset)
        :ok = :file.truncate(file)
        :file.sync(file)
      end)

    Logger.warning(
      "truncated incomplete event log tail path=#{path} removed_bytes=#{removed_bytes}"
    )
  end

  defp validate_sequence!([]), do: :ok

  defp validate_sequence!([%Event{type: :snapshot_recorded} | _] = events) do
    validate_from(events, events |> hd() |> Map.fetch!(:sequence))
  end

  defp validate_sequence!(events) do
    validate_from(events, 1)
  end

  defp validate_from(events, expected) do
    result =
      Enum.reduce_while(events, expected, fn event, expected ->
        if event.sequence == expected, do: {:cont, expected + 1}, else: {:halt, :error}
      end)

    if result == :error, do: raise("event log sequence is not contiguous")
  end
end
