defmodule ReyCode.Tool.Eval do
  @moduledoc "Runs bounded code in a persistent Python or JavaScript kernel."

  @behaviour ReyCode.Tool

  alias ReyCode.EvalHub
  alias ReyCode.RuntimeConfig.Tools.Evaluation
  alias ReyCode.Tool.{Request, Result, Support}

  @actions ~w(start run stop list)

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace} = request, opts) do
    %Evaluation{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, action} <- Support.require_arg(arguments, :action),
         true <- action in @actions,
         {:ok, hub} <- ReyCode.ResourceScopes.fetch(request, EvalHub) do
      execute(action, arguments, workspace, {policy, hub})
    else
      false -> Result.error(:unsupported_evaluation_action)
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Evaluation is host execution, classified as a mutation."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in @actions

  defp execute("start", arguments, workspace, {policy, hub}) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, language} <- language(arguments),
         {:ok, snapshot} <- EvalHub.start(name, language, workspace, policy, hub) do
      Result.ok(Jason.encode!(snapshot))
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("run", arguments, _workspace, {_policy, hub}) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         {:ok, code} <- Support.require_arg(arguments, :code),
         {:ok, result} <- EvalHub.evaluate(name, code, hub) do
      Result.ok(Jason.encode!(result), metadata: %{"kernel" => name})
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("stop", arguments, _workspace, {_policy, hub}) do
    with {:ok, name} <- Support.require_arg(arguments, :name),
         :ok <- EvalHub.stop(name, hub) do
      Result.ok("stopped #{name}")
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("list", _arguments, _workspace, {_policy, hub}) do
    EvalHub.list(hub) |> Jason.encode!() |> Result.ok()
  end

  defp language(arguments) do
    case Map.get(arguments, "language", Map.get(arguments, :language)) do
      "python" -> {:ok, :python}
      "javascript" -> {:ok, :javascript}
      "js" -> {:ok, :javascript}
      :python -> {:ok, :python}
      :javascript -> {:ok, :javascript}
      _ -> {:error, :unsupported_evaluation_language}
    end
  end
end
