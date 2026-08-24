defmodule ReyCode.ToolRegistry do
  @moduledoc """
  Dispatches provider ToolCalls under the Workspace trust and approval model.

  Unknown tools fail closed. Read-only and edit tools execute only after path
  containment has been established; Bash and Write return an approval request
  and perform no side effect before the Owner resolves the durable ToolRun.
  Each adapter receives only its focused, bounded policy. Tool results are
  explicit success/failure values; process timeout and cancellation behavior
  belong to the adapter implementation.
  """

  alias ReyCode.Security.Workspace
  alias ReyCode.Tool.{Request, Result}

  @tools %{
    "read" => ReyCode.Tool.Read,
    "write" => ReyCode.Tool.Write,
    "edit" => ReyCode.Tool.Edit,
    "bash" => ReyCode.Tool.Bash,
    "grep" => ReyCode.Tool.Grep,
    "glob" => ReyCode.Tool.Glob,
    "list" => ReyCode.Tool.List
  }

  @ask_tools MapSet.new(["bash", "write"])

  @type decision :: {:ok, Result.t()} | {:ask, Request.t()} | {:deny, atom()}

  @doc """
  Evaluates a tool request against the trust boundary.

  Returns:

    - `{:ask, request}` when the tool requires owner approval (it is not executed here).
    - `{:ok, result}` when the tool is allowed and has been executed.
    - `{:deny, reason}` when the tool is unknown.
  """
  @spec dispatch(Request.t(), ReyCode.RuntimeConfig.t()) :: decision()
  def dispatch(%Request{} = request, policy) do
    request = with_policy_roots(request, policy)
    name = to_string(request.tool)

    case Map.fetch(@tools, name) do
      {:ok, _module} ->
        if MapSet.member?(@ask_tools, name) do
          {:ask, request}
        else
          {:ok, execute(request, policy)}
        end

      :error ->
        {:deny, :unknown_tool}
    end
  end

  @doc "Executes a previously approved (or allow-listed) tool request under frozen policy."
  @spec execute(Request.t(), ReyCode.RuntimeConfig.t()) :: Result.t()
  def execute(%Request{} = request, policy) do
    request = with_policy_roots(request, policy)
    name = to_string(request.tool)

    case Map.fetch(@tools, name) do
      {:ok, module} -> module.run(request, policy: tool_policy(policy, name))
      :error -> Result.error(:unknown_tool)
    end
  end

  defp with_policy_roots(request, policy),
    do: %{request | roots: Workspace.roots(policy.workspace)}

  defp tool_policy(config, "bash"), do: config.tools.bash
  defp tool_policy(config, "read"), do: config.tools.read
  defp tool_policy(config, "edit"), do: config.tools.edit
  defp tool_policy(config, "write"), do: config.tools.write
  defp tool_policy(config, "glob"), do: config.tools.glob
  defp tool_policy(config, "list"), do: config.tools.list
  defp tool_policy(config, "grep"), do: config.tools.grep

  @doc "Whether a tool name requires owner approval before execution."
  @spec requires_approval?(Request.t() | String.t() | atom()) :: boolean()
  def requires_approval?(%Request{tool: tool}), do: requires_approval?(tool)
  def requires_approval?(tool), do: MapSet.member?(@ask_tools, to_string(tool))

  @doc "The set of registered tool names."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tools |> Map.keys() |> Enum.sort()
end
