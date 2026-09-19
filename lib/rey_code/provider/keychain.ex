defmodule ReyCode.Provider.Keychain do
  @moduledoc """
  macOS Keychain persistence for provider API keys under the "ReyCode" service.

  Every operation runs the `security` CLI through the bounded provider task
  supervisor with a hard deadline. Values never appear in logs; only the
  requested key is ever returned. Unsupported platforms and CLI failures
  return tagged errors so callers degrade to session or environment
  credentials instead of failing provider setup.
  """

  @service "ReyCode"
  @deadline_ms 2_000
  @max_secret_bytes 4_096

  @type error :: :keychain_unsupported | {:keychain_failed, String.t()}

  @doc "Whether this platform can persist credentials in a system keychain."
  @spec supported?() :: boolean()
  def supported?, do: match?({:unix, :darwin}, :os.type())

  @doc "Stores or replaces the secret for one key environment name."
  @spec store(String.t(), String.t()) :: :ok | {:error, error()}
  def store(key_env, secret)
      when is_binary(key_env) and key_env != "" and is_binary(secret) do
    cond do
      byte_size(secret) > @max_secret_bytes ->
        {:error, {:keychain_failed, "secret exceeds the #{@max_secret_bytes} byte limit"}}

      not supported?() ->
        {:error, :keychain_unsupported}

      true ->
        run(["add-generic-password", "-U", "-s", @service, "-a", key_env, "-w", secret])
        |> store_result()
    end
  end

  @doc "Reads the stored secret for one key environment name, if present."
  @spec read(String.t()) :: {:ok, String.t()} | :error
  def read(key_env) when is_binary(key_env) and key_env != "" do
    if supported?() do
      case run(["find-generic-password", "-s", @service, "-a", key_env, "-w"]) do
        {secret, 0} -> {:ok, String.trim_trailing(secret, "\n")}
        {_output, _status} -> :error
      end
    else
      :error
    end
  end

  @doc "Removes the stored secret; removing an absent entry is idempotent."
  @spec delete(String.t()) :: :ok | {:error, error()}
  def delete(key_env) when is_binary(key_env) and key_env != "" do
    if supported?() do
      delete_stored(key_env)
    else
      :ok
    end
  end

  defp delete_stored(key_env) do
    case run(["delete-generic-password", "-s", @service, "-a", key_env]) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        deletion_result(output)
    end
  end

  defp deletion_result(output) do
    if String.contains?(output, "could not be found"),
      do: :ok,
      else: {:error, {:keychain_failed, clip(output)}}
  end

  defp store_result({_output, 0}), do: :ok
  defp store_result({output, _status}), do: {:error, {:keychain_failed, clip(output)}}

  # The security CLI is an external binary whose failure output is not
  # controlled; bound it before any caller could retain it.
  defp clip(output), do: String.slice(output, 0, 200)

  defp run(args) do
    task =
      Task.Supervisor.async_nolink(ReyCode.ProviderTaskSupervisor, fn ->
        System.cmd("security", args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _deadline -> {"security exceeded its deadline", 1}
    end
  rescue
    error in [ErlangError, File.Error] ->
      {"security unavailable: #{Exception.message(error)}", 1}
  end
end
