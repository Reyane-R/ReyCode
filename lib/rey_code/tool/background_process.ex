defmodule ReyCode.Tool.BackgroundProcess do
  @moduledoc "Controls bounded named processes owned by `ReyCode.ProcessHub`."

  @behaviour ReyCode.Tool

  alias ReyCode.ProcessHub
  alias ReyCode.RuntimeConfig.Tools.BackgroundProcess, as: ProcessPolicy
  alias ReyCode.Tool.{Request, Result, Support}

  @actions ~w(start logs list wait stop restart)
  @mutating_actions ~w(start stop restart)

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, opts) do
    %ProcessPolicy{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, action} <- Support.require_arg(arguments, :action),
         true <- action in @actions do
      execute(action, arguments, workspace, policy)
    else
      false -> Result.error(:unsupported_process_action)
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Returns true when one process action changes supervised runtime state."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in @mutating_actions

  defp execute("start", arguments, workspace, policy) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, command} <- require_command(arguments),
         {:ok, snapshot} <- ProcessHub.start(name, command, workspace, policy) do
      Result.ok("started #{name}", metadata: wire_snapshot(snapshot))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("logs", arguments, _workspace, _policy) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, logs} <- ProcessHub.logs(name) do
      Result.ok(Jason.encode!(logs),
        truncated: logs["truncated"],
        metadata: %{"name" => name, "output_bytes" => logs["output_bytes"]}
      )
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("list", _arguments, _workspace, _policy) do
    ProcessHub.list()
    |> Enum.map(&wire_snapshot/1)
    |> Jason.encode!()
    |> Result.ok()
  end

  defp execute("wait", arguments, _workspace, policy) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, pattern} <- Support.require_arg(arguments, :pattern),
         {:ok, timeout_ms} <-
           Support.integer_arg(arguments, :timeout_ms, policy.stop_timeout_ms),
         true <- timeout_ms > 0,
         {:ok, logs} <- ProcessHub.await(name, pattern, timeout_ms) do
      Result.ok(Jason.encode!(logs),
        truncated: logs["truncated"],
        metadata: %{"name" => name, "output_bytes" => logs["output_bytes"]}
      )
    else
      false -> Result.error(:invalid_process_wait_timeout)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("stop", arguments, _workspace, _policy) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         :ok <- ProcessHub.stop(name) do
      Result.ok("stopped #{name}", metadata: %{"name" => name})
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("restart", arguments, _workspace, _policy) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, snapshot} <- ProcessHub.restart(name) do
      Result.ok("restarted #{name}", metadata: wire_snapshot(snapshot))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp require_command(arguments) do
    case Map.fetch(arguments, "command") do
      {:ok, command} ->
        validate_command(command)

      :error ->
        case Map.fetch(arguments, :command) do
          {:ok, command} -> validate_command(command)
          :error -> {:error, {:missing_argument, :command}}
        end
    end
  end

  defp validate_command([executable | args] = command)
       when is_binary(executable) and executable != "" and is_list(args) do
    if Enum.all?(args, &is_binary/1),
      do: {:ok, command},
      else: {:error, {:invalid_argument, :command}}
  end

  defp validate_command(_command), do: {:error, {:invalid_argument, :command}}

  defp wire_snapshot(snapshot) do
    %{
      "name" => snapshot.name,
      "command" => snapshot.command,
      "workspace" => snapshot.workspace,
      "status" => Atom.to_string(snapshot.status),
      "exit_status" => snapshot.exit_status,
      "output_bytes" => snapshot.output_bytes,
      "truncated" => snapshot.truncated
    }
  end
end
