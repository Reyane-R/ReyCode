defmodule ReyCode.Memory.Store do
  @moduledoc "Append-only SQLite project memory with retain, recall, learn, and invalidate operations."

  use GenServer

  alias Exqlite.Sqlite3

  @max_value_bytes 32_768
  @max_entries 10_000
  @max_recall 100

  @type memory :: %{
          id: String.t(),
          project: String.t(),
          kind: String.t(),
          key: String.t(),
          value: String.t(),
          tags: [String.t()],
          created_at: String.t(),
          active: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def retain(project, key, value, tags \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:retain, project, key, value, tags})

  def learn(project, key, value, tags \\ [], server \\ __MODULE__),
    do: GenServer.call(server, {:learn, project, key, value, tags})

  def recall(project, query, count \\ 20, server \\ __MODULE__),
    do: GenServer.call(server, {:recall, project, query, count})

  def forget(project, key, server \\ __MODULE__),
    do: GenServer.call(server, {:forget, project, key})

  def reflect(project, server \\ __MODULE__), do: GenServer.call(server, {:reflect, project})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Path.join(ReyCode.Paths.data_home(), "memory.sqlite3"))
    :ok = path |> Path.dirname() |> File.mkdir_p()

    with {:ok, connection} <- Sqlite3.open(path),
         :ok <- Sqlite3.execute(connection, "PRAGMA journal_mode = WAL"),
         :ok <- Sqlite3.execute(connection, "PRAGMA busy_timeout = 5000"),
         :ok <-
           Sqlite3.execute(
             connection,
             "CREATE TABLE IF NOT EXISTS memory_events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL, project TEXT NOT NULL, kind TEXT NOT NULL, memory_key TEXT NOT NULL, value TEXT NOT NULL, tags TEXT NOT NULL, active INTEGER NOT NULL, created_at TEXT NOT NULL)"
           ),
         {:ok, memories} <- load_memories(connection) do
      {:ok, %{connection: connection, path: path, memories: memories}}
    else
      {:error, reason} -> {:stop, {:memory_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({kind, project, key, value, tags}, _from, state)
      when kind in [:retain, :learn] do
    with :ok <- valid_text(project),
         :ok <- valid_text(key),
         :ok <- valid_value(value),
         {:ok, tags} <- valid_tags(tags),
         :ok <- capacity(state, project),
         {:ok, memory} <- append(state, project, Atom.to_string(kind), key, value, tags, true) do
      {:reply, {:ok, memory}, put_memory(state, memory)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:recall, project, query, count}, _from, state) do
    if is_binary(project) and is_binary(query) do
      entries =
        state.memories
        |> Map.values()
        |> Enum.filter(&(&1.active and &1.project == project and matches?(&1, query)))
        |> Enum.sort_by(& &1.created_at, :desc)
        |> Enum.take(min(max(count, 1), @max_recall))

      {:reply, {:ok, entries}, state}
    else
      {:reply, {:error, :invalid_memory_query}, state}
    end
  end

  def handle_call({:forget, project, key}, _from, state) do
    case Enum.find(
           Map.values(state.memories),
           &(&1.active and &1.project == project and &1.key == key)
         ) do
      nil ->
        {:reply, {:error, :memory_not_found}, state}

      memory ->
        {:ok, invalidated} =
          append(state, project, "invalidated", key, memory.value, memory.tags, false)

        {:reply, :ok, put_memory(state, invalidated)}
    end
  end

  def handle_call({:reflect, project}, _from, state) do
    memories =
      state.memories
      |> Map.values()
      |> Enum.filter(&(&1.active and &1.project == project))
      |> Enum.sort_by(& &1.created_at, :desc)
      |> Enum.take(@max_recall)

    {:reply, {:ok, %{project: project, count: length(memories), memories: memories}}, state}
  end

  @impl true
  def terminate(_reason, %{connection: connection}), do: Sqlite3.close(connection)

  defp append(state, project, kind, key, value, tags, active) do
    id = "memory-#{System.unique_integer([:positive, :monotonic])}"
    timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    tags_json = Jason.encode!(tags)

    {:ok, statement} =
      Sqlite3.prepare(
        state.connection,
        "INSERT INTO memory_events (event_id, project, kind, memory_key, value, tags, active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
      )

    try do
      :ok =
        Sqlite3.bind(statement, [
          id,
          project,
          kind,
          key,
          value,
          tags_json,
          if(active, do: 1, else: 0),
          timestamp
        ])

      :done = Sqlite3.step(state.connection, statement)

      {:ok,
       %{
         id: id,
         project: project,
         kind: kind,
         key: key,
         value: value,
         tags: tags,
         created_at: timestamp,
         active: active
       }}
    after
      Sqlite3.release(state.connection, statement)
    end
  rescue
    error -> {:error, {:memory_write_failed, Exception.message(error)}}
  end

  defp load_memories(connection) do
    {:ok, rows} =
      fetch_all(
        connection,
        "SELECT event_id, project, kind, memory_key, value, tags, active, created_at FROM memory_events ORDER BY sequence"
      )

    {:ok, Enum.reduce(rows, %{}, &apply_row/2)}
  end

  defp fetch_all(connection, sql) do
    {:ok, statement} = Sqlite3.prepare(connection, sql)

    try do
      Sqlite3.fetch_all(connection, statement)
    after
      Sqlite3.release(connection, statement)
    end
  end

  defp apply_row([id, project, kind, key, value, tags_json, active, created_at], memories) do
    memory = %{
      id: id,
      project: project,
      kind: kind,
      key: key,
      value: value,
      tags: Jason.decode!(tags_json),
      created_at: created_at,
      active: active == 1
    }

    Map.put(memories, {project, key}, memory)
  end

  defp valid_text(value) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp valid_text(_), do: {:error, :invalid_memory_text}
  defp valid_value(value) when is_binary(value) and byte_size(value) <= @max_value_bytes, do: :ok
  defp valid_value(_), do: {:error, :memory_value_too_large}

  defp valid_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &(is_binary(&1) and byte_size(&1) <= 256)),
      do: {:ok, Enum.uniq(tags)},
      else: {:error, :invalid_memory_tags}
  end

  defp valid_tags(_), do: {:error, :invalid_memory_tags}

  defp capacity(state, project),
    do:
      if(
        Enum.count(state.memories, fn {{p, _}, memory} -> p == project and memory.active end) <
          @max_entries,
        do: :ok,
        else: {:error, :memory_limit_reached}
      )

  defp put_memory(state, memory),
    do: %{state | memories: Map.put(state.memories, {memory.project, memory.key}, memory)}

  defp matches?(_memory, ""), do: true

  defp matches?(memory, query),
    do:
      String.contains?(
        String.downcase(memory.key <> " " <> memory.value <> " " <> Enum.join(memory.tags, " ")),
        String.downcase(query)
      )
end
