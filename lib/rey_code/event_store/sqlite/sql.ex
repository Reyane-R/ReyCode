defmodule ReyCode.EventStore.SQLite.Sql do
  @moduledoc """
  Centralized low-level SQL primitives for the SQLite event store.

  Statement prepare/bind/step/release, scalar reads, and transaction
  begin/commit/rollback live here and only here; higher-level persistence
  modules compose these primitives instead of duplicating them.
  """

  alias Exqlite.Sqlite3

  @doc "Runs a SELECT and returns all rows."
  @spec rows(term(), String.t(), list()) :: [list()]
  def rows(connection, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(connection, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(connection, statement)
      rows
    after
      Sqlite3.release(connection, statement)
    end
  end

  @doc "Runs a write statement to completion, raising on unexpected results."
  @spec run!(term(), String.t(), list()) :: :ok
  def run!(connection, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(connection, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      :done = Sqlite3.step(connection, statement)
      :ok
    after
      Sqlite3.release(connection, statement)
    end
  end

  @doc "Runs a raw SQL string without parameters."
  @spec execute(term(), String.t()) :: :ok | {:error, term()}
  def execute(connection, sql), do: Sqlite3.execute(connection, sql)

  @doc "Runs a raw SQL string that must succeed."
  @spec execute!(term(), String.t()) :: :ok
  def execute!(connection, sql) do
    :ok = execute(connection, sql)
  end

  @doc "Runs a SELECT that must return exactly one single-column row."
  @spec scalar(term(), String.t()) :: {:ok, term()} | {:error, term()}
  def scalar(connection, sql) do
    case rows(connection, sql) do
      [[value]] -> {:ok, value}
      result -> {:error, {:unexpected_query_result, result}}
    end
  end

  @doc "Like `scalar/2` but unwraps or raises."
  @spec scalar!(term(), String.t()) :: term()
  def scalar!(connection, sql) do
    {:ok, value} = scalar(connection, sql)
    value
  end

  @doc """
  Runs an operation inside BEGIN IMMEDIATE/COMMIT.

  A raised exception rolls back and reraises; a thrown `{:conflict, reason}`
  rolls back and returns an error tuple.
  """
  @spec transaction(term(), (-> result)) :: :ok | {:ok, result} | {:error, term()}
        when result: term()
  def transaction(connection, operation) do
    with :ok <- execute(connection, "BEGIN IMMEDIATE") do
      try do
        result = operation.()

        case execute(connection, "COMMIT") do
          :ok -> if(result == :ok, do: :ok, else: {:ok, result})
          {:error, reason} -> {:error, {:commit_unknown, reason}}
        end
      rescue
        error ->
          stacktrace = __STACKTRACE__
          _ = execute(connection, "ROLLBACK")
          reraise error, stacktrace
      catch
        {:conflict, actual} ->
          rollback(connection, {:conflict, actual})
      end
    end
  end

  defp rollback(connection, failure) do
    case execute(connection, "ROLLBACK") do
      :ok -> {:error, failure}
      {:error, reason} -> {:error, {:rollback_failed, failure, reason}}
    end
  end

  @doc "Generates a unique append-transaction identifier."
  @spec transaction_id() :: String.t()
  def transaction_id do
    "tx-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc "Returns the store's millisecond-precision ISO-8601 timestamp."
  @spec now() :: String.t()
  def now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
end
