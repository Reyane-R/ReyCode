defmodule ReyCode.Tool.Memory do
  @moduledoc "Stores and retrieves bounded project-scoped durable memory."

  @behaviour ReyCode.Tool

  alias ReyCode.Memory.Store
  alias ReyCode.Tool.{Request, Result, Support}

  @actions ~w(retain recall learn forget reflect)

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, _opts) do
    with {:ok, action} <- Support.require_arg(arguments, :action), true <- action in @actions do
      execute(action, arguments, workspace)
    else
      false -> Result.error(:unsupported_memory_action)
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Memory mutations require owner approval; recall and reflect are read-only."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in ["retain", "learn", "forget"]

  defp execute(action, arguments, workspace) when action in ["retain", "learn"] do
    with {:ok, key} <- Support.require_arg(arguments, :key),
         {:ok, value} <- Support.require_arg(arguments, :value),
         {:ok, tags} <- tags(arguments),
         {:ok, memory} <- store_memory(action, workspace, key, value, tags) do
      Result.ok(Jason.encode!(memory))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("recall", arguments, workspace) do
    with {:ok, query} <- Support.require_arg(arguments, :query),
         {:ok, memories} <- Store.recall(workspace, query) do
      Result.ok(Jason.encode!(memories))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("reflect", _arguments, workspace) do
    case Store.reflect(workspace) do
      {:ok, reflection} -> Result.ok(Jason.encode!(reflection))
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("forget", arguments, workspace) do
    with {:ok, key} <- Support.require_arg(arguments, :key),
         :ok <- Store.forget(workspace, key) do
      Result.ok("forgot #{key}")
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp store_memory("retain", workspace, key, value, tags),
    do: Store.retain(workspace, key, value, tags)

  defp store_memory("learn", workspace, key, value, tags),
    do: Store.learn(workspace, key, value, tags)

  defp tags(arguments) do
    case Map.get(arguments, "tags", Map.get(arguments, :tags, [])) do
      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1), do: {:ok, tags}, else: {:error, :invalid_memory_tags}

      _ ->
        {:error, :invalid_memory_tags}
    end
  end
end
