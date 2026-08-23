defmodule ReyCode.Provider.OpenCode.Process do
  @moduledoc "Launches the OpenCode CLI and streams raw output within a total deadline."

  alias ReyCode.Provider.Request
  alias ReyCode.Security.Environment

  @spec launch_args(Request.t()) :: [binary()]
  def launch_args(%Request{} = request) do
    [
      "run",
      "--format",
      "json",
      "--model",
      request.participant.model,
      "--dir",
      request.workspace
    ]
  end

  @spec open_stream(binary(), [binary()], binary(), binary()) :: Enumerable.t()
  def open_stream(executable, args, workspace, prompt) do
    {wrapper, wrapped_args, env} =
      Environment.wrap(executable, args, environment_opts())

    exile_stream([wrapper | wrapped_args],
      input: [prompt],
      stderr: :consume,
      ignore_epipe: true,
      exit_timeout: 1_000,
      max_chunk_size: 65_535,
      cd: workspace,
      env: env
    )
  end

  @spec collect(
          Enumerable.t(),
          (term(), term() -> {:cont, term()} | {:halt, term()}),
          term(),
          non_neg_integer()
        ) :: {:ok, term()} | {:error, map()}
  def collect(stream, reducer, acc, timeout) do
    collect(stream, reducer, acc, timeout, [])
  end

  @spec collect(
          Enumerable.t(),
          (term(), term() -> {:cont, term()} | {:halt, term()}),
          term(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, term()} | {:error, map()}
  def collect(stream, reducer, acc, timeout, opts) do
    owner = self()
    tag = make_ref()
    deadline = monotonic_ms() + timeout
    next_deadline = Keyword.get(opts, :next_deadline, fn _acc -> nil end)
    on_deadline = Keyword.get(opts, :on_deadline, fn current, _now -> current end)
    task = collect_stream_task(stream, owner, tag)

    loop = %{
      reducer: reducer,
      deadline: deadline,
      timeout: timeout,
      next_deadline: next_deadline,
      on_deadline: on_deadline
    }

    try do
      collect_loop(task, tag, acc, loop)
    rescue
      exception ->
        Task.shutdown(task, :brutal_kill)
        drain_relay(tag)
        {:error, error("launch_failed", Exception.message(exception))}
    catch
      kind, reason ->
        Task.shutdown(task, :brutal_kill)
        drain_relay(tag)
        {:error, error("launch_failed", Exception.format_banner(kind, reason))}
    end
  end

  @doc false
  @spec environment_opts() :: keyword()
  def environment_opts do
    [
      source: System.get_env(),
      additional_names: Application.get_env(:rey_code, :opencode_env_allowlist, []),
      cpu_seconds: Application.get_env(:rey_code, :opencode_cpu_seconds, 900),
      open_files: Application.get_env(:rey_code, :opencode_open_files, 1_024)
    ]
  end

  defp collect_stream_task(stream, owner, tag) do
    Task.async(fn ->
      try do
        _ =
          Enum.reduce_while(stream, :ok, fn item, :ok ->
            acknowledgement = make_ref()
            send(owner, {tag, :item, acknowledgement, item})

            receive do
              {^tag, ^acknowledgement, :cont} -> {:cont, :ok}
              {^tag, ^acknowledgement, :halt} -> {:halt, :ok}
            end
          end)

        {:ok, :done}
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, reason -> {:error, Exception.format_banner(kind, reason)}
      end
    end)
  end

  defp collect_loop(task, tag, acc, loop) do
    now = monotonic_ms()
    flush_deadline = loop.next_deadline.(acc)

    cond do
      now >= loop.deadline ->
        timeout(task, tag, loop.timeout)

      is_integer(flush_deadline) and now >= flush_deadline ->
        flush_and_continue(task, tag, acc, loop, now)

      true ->
        receive_for = min_deadline(loop.deadline, flush_deadline) - now
        receive_item(task, tag, acc, loop, receive_for)
    end
  end

  defp flush_and_continue(task, tag, acc, loop, now) do
    case call_before(fn -> loop.on_deadline.(acc, now) end, loop.deadline) do
      {:ok, next} ->
        collect_loop(task, tag, next, loop)

      {:error, message} ->
        stop_with_error(task, tag, message)

      :timeout ->
        timeout(task, tag, loop.timeout)
    end
  end

  defp receive_item(task, tag, acc, loop, receive_for) do
    receive do
      {^tag, :item, acknowledgement, item} ->
        result = call_before(fn -> loop.reducer.(item, acc) end, loop.deadline)
        handle_reducer_result(result, task, tag, loop, acknowledgement)

      {reference, result} when reference == task.ref ->
        Process.demonitor(task.ref, [:flush])
        producer_result(result, acc)

      {:DOWN, reference, :process, _pid, reason} when reference == task.ref ->
        {:error, error("launch_failed", inspect(reason))}
    after
      max(receive_for, 0) ->
        collect_loop(task, tag, acc, loop)
    end
  end

  defp handle_reducer_result(
         {:ok, {:cont, next}},
         task,
         tag,
         loop,
         acknowledgement
       ) do
    send(task.pid, {tag, acknowledgement, :cont})
    collect_loop(task, tag, next, loop)
  end

  defp handle_reducer_result(
         {:ok, {:halt, next}},
         task,
         tag,
         loop,
         acknowledgement
       ) do
    send(task.pid, {tag, acknowledgement, :halt})
    await_halt(task, tag, next, loop.deadline, loop.timeout)
  end

  defp handle_reducer_result(
         {:error, message},
         task,
         tag,
         _loop,
         acknowledgement
       ) do
    send(task.pid, {tag, acknowledgement, :halt})
    stop_with_error(task, tag, message)
  end

  defp handle_reducer_result(
         :timeout,
         task,
         tag,
         loop,
         acknowledgement
       ) do
    send(task.pid, {tag, acknowledgement, :halt})
    timeout(task, tag, loop.timeout)
  end

  defp await_halt(task, tag, acc, deadline, timeout) do
    case Task.yield(task, max(deadline - monotonic_ms(), 0)) do
      {:ok, result} -> producer_result(result, acc)
      {:exit, reason} -> {:error, error("launch_failed", inspect(reason))}
      nil -> timeout(task, tag, timeout)
    end
  end

  defp producer_result({:ok, :done}, acc), do: {:ok, acc}
  defp producer_result({:error, message}, _acc), do: {:error, error("launch_failed", message)}

  defp stop_with_error(task, tag, message) do
    _ = Task.shutdown(task, :brutal_kill)
    drain_relay(tag)
    {:error, error("launch_failed", message)}
  end

  defp timeout(task, tag, timeout) do
    _ = Task.shutdown(task, :brutal_kill)
    drain_relay(tag)
    {:error, error("timeout", "OpenCode did not finish within #{timeout}ms")}
  end

  defp min_deadline(deadline, nil), do: deadline
  defp min_deadline(deadline, flush_deadline), do: min(deadline, flush_deadline)

  defp drain_relay(tag) do
    receive do
      {^tag, :item, _acknowledgement, _item} -> drain_relay(tag)
    after
      0 -> :ok
    end
  end

  defp call_before(fun, deadline) do
    remaining = max(deadline - monotonic_ms(), 0)

    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          exception -> {:error, Exception.message(exception)}
        catch
          kind, reason -> {:error, Exception.format_banner(kind, reason)}
        end
      end)

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, inspect(reason)}
      nil -> :timeout
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp exile_stream(args, opts) do
    module = Exile
    module.stream(args, opts)
  end

  defp error(category, message) do
    %{"category" => category, "message" => message, "retryable" => false}
  end
end
