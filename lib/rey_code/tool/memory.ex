defmodule ReyCode.Tool.Memory do
  @moduledoc "Stores and retrieves bounded project-scoped durable memory."

  @behaviour ReyCode.Tool

  alias ReyCode.Memory.Store
  alias ReyCode.Tool.{Request, Result, Support}

  @actions ~w(retain recall learn forget reflect)
  @structured_kinds ~w(decision assumption)

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, opts) do
    server = Keyword.get(opts, :server, Store)

    with {:ok, action} <- Support.require_arg(arguments, :action), true <- action in @actions do
      execute(action, arguments, workspace, server)
    else
      false -> Result.error(:unsupported_memory_action)
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Memory mutations require owner approval; recall and reflect are read-only."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in ["retain", "learn", "forget"]

  defp execute(action, arguments, workspace, server) when action in ["retain", "learn"] do
    with {:ok, key} <- Support.require_arg(arguments, :key),
         {:ok, value} <- Support.require_arg(arguments, :value),
         {:ok, tags} <- tags(arguments),
         {:ok, kind} <- memory_kind(arguments),
         {:ok, value, tags} <- prepare_value(kind, value, tags, arguments),
         {:ok, memory} <- store_memory(action, kind, workspace, key, value, tags, server) do
      Result.ok(Jason.encode!(memory))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("recall", arguments, workspace, server) do
    with {:ok, query} <- Support.require_arg(arguments, :query),
         {:ok, memories} <- Store.recall(workspace, query, 20, server) do
      Result.ok(Jason.encode!(memories))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("reflect", _arguments, workspace, server) do
    case Store.reflect(workspace, server) do
      {:ok, reflection} -> Result.ok(Jason.encode!(reflection))
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("forget", arguments, workspace, server) do
    with {:ok, key} <- Support.require_arg(arguments, :key),
         :ok <- Store.forget(workspace, key, server) do
      Result.ok("forgot #{key}")
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp store_memory("retain", nil, workspace, key, value, tags, server),
    do: Store.retain(workspace, key, value, tags, server)

  defp store_memory("learn", nil, workspace, key, value, tags, server),
    do: Store.learn(workspace, key, value, tags, server)

  defp store_memory(_action, kind, workspace, key, value, tags, server),
    do: Store.record(workspace, kind, key, value, tags, server)

  defp memory_kind(arguments) do
    case Map.get(arguments, "kind", Map.get(arguments, :kind)) do
      nil -> {:ok, nil}
      kind when kind in ~w(decision assumption fact lesson) -> {:ok, kind}
      _kind -> {:error, :invalid_memory_kind}
    end
  end

  defp prepare_value(nil, value, tags, _arguments), do: {:ok, value, tags}

  defp prepare_value(kind, value, tags, arguments) when kind in @structured_kinds do
    with {:ok, rationale} <- optional_text(arguments, "rationale"),
         {:ok, alternatives} <- optional_text(arguments, "alternatives"),
         {:ok, evidence} <- optional_text(arguments, "evidence"),
         {:ok, encoded} <-
           Jason.encode(%{
             "statement" => value,
             "rationale" => rationale,
             "alternatives" => alternatives,
             "evidence" => evidence
           }) do
      {:ok, encoded, Enum.uniq([kind | tags])}
    else
      _error -> {:error, :invalid_memory_value}
    end
  end

  defp prepare_value(kind, value, tags, _arguments),
    do: {:ok, value, Enum.uniq([kind | tags])}

  defp optional_text(arguments, key) do
    case Map.get(arguments, key, Map.get(arguments, atom_key(key))) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, :invalid_memory_value}
    end
  end

  defp atom_key("rationale"), do: :rationale
  defp atom_key("alternatives"), do: :alternatives
  defp atom_key("evidence"), do: :evidence

  defp tags(arguments) do
    case Map.get(arguments, "tags", Map.get(arguments, :tags, [])) do
      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1), do: {:ok, tags}, else: {:error, :invalid_memory_tags}

      _ ->
        {:error, :invalid_memory_tags}
    end
  end
end
