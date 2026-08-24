defmodule ReyCode.Tool.DirectoryEntries do
  @moduledoc "Streams a bounded number of direct directory entries through the platform find utility."

  @find_paths ["/usr/bin/find", "/bin/find"]

  @spec take(Path.t(), pos_integer(), pos_integer()) ::
          {:ok, [String.t()], boolean()} | {:error, term()}
  def take(path, max_entries, timeout_ms)
      when is_binary(path) and is_integer(max_entries) and max_entries > 0 and
             is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, executable} <- find_executable(),
         {:ok, port} <- open(executable, path) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      collect(port, path, max_entries + 1, deadline, %{buffer: "", entries: [], count: 0})
    end
  end

  defp find_executable do
    case Enum.find(@find_paths, &File.exists?/1) do
      nil -> {:error, :directory_lister_unavailable}
      executable -> {:ok, executable}
    end
  end

  defp open(executable, path) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [path, "-mindepth", "1", "-maxdepth", "1", "-print0"]
      ])

    {:ok, port}
  rescue
    error in ErlangError -> {:error, {:directory_lister_failed, Exception.message(error)}}
  end

  defp collect(port, root, limit, deadline, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        {records, buffer} = split_records(state.buffer <> data)
        state = state |> Map.put(:buffer, buffer) |> add_records(records, root, limit)

        if state.count >= limit do
          close(port)
          {:ok, state.entries |> Enum.reverse() |> Enum.take(limit - 1), true}
        else
          collect(port, root, limit, deadline, state)
        end

      {^port, {:exit_status, 0}} ->
        finish(state, root, limit)

      {^port, {:exit_status, status}} ->
        {:error, {:directory_listing_failed, status}}
    after
      remaining ->
        close(port)
        {:error, :directory_listing_timeout}
    end
  end

  defp split_records(data) do
    parts = :binary.split(data, <<0>>, [:global])
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp add_records(state, records, root, limit) do
    Enum.reduce_while(records, state, fn record, acc ->
      if acc.count >= limit do
        {:halt, acc}
      else
        {:cont, add_record(acc, record, root)}
      end
    end)
  end

  defp add_record(state, "", _root), do: state

  defp add_record(state, record, root) do
    case Path.dirname(record) do
      ^root -> %{state | entries: [Path.basename(record) | state.entries], count: state.count + 1}
      _other -> state
    end
  end

  defp finish(%{buffer: ""} = state, _root, _limit),
    do: {:ok, Enum.reverse(state.entries), false}

  defp finish(state, root, limit) do
    state = add_records(%{state | buffer: ""}, [state.buffer], root, limit)
    {:ok, Enum.reverse(state.entries), state.count >= limit}
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
