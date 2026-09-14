defmodule ReyCode.ToolRegistry do
  @moduledoc """
  Dispatches provider ToolCalls under the Workspace trust and approval model.

  Unknown tools fail closed. Supported tools execute directly by default;
  configured ask rules wait for the Owner to resolve the durable ToolRun.
  Filesystem adapters establish path containment before performing effects.
  Each adapter receives only its focused, bounded policy. Tool results are
  explicit success/failure values; process timeout and cancellation behavior
  belong to the adapter implementation.
  """

  alias ReyCode.Security.{Permissions, VerifiedChangeBoundary, Workspace}

  alias ReyCode.Tool.{Request, Result}

  @tools %{
    "artifact_read" => ReyCode.Tool.ArtifactRead,
    "read" => ReyCode.Tool.Read,
    "write" => ReyCode.Tool.Write,
    "edit" => ReyCode.Tool.Edit,
    "bash" => ReyCode.Tool.Bash,
    "grep" => ReyCode.Tool.Grep,
    "glob" => ReyCode.Tool.Glob,
    "list" => ReyCode.Tool.List,
    "lsp" => ReyCode.Tool.LSP,
    "git" => ReyCode.Tool.Git,
    "process" => ReyCode.Tool.BackgroundProcess,
    "debug" => ReyCode.Tool.Debug,
    "eval" => ReyCode.Tool.Eval,
    "memory" => ReyCode.Tool.Memory,
    "web_search" => ReyCode.Tool.WebSearch,
    "read_url" => ReyCode.Tool.DocumentRead
  }

  @type decision :: {:ok, Result.t()} | {:ask, Request.t()} | {:deny, term()}

  @doc """
  Evaluates a tool request against the trust boundary.

  Returns:

    - `{:ask, request}` when the tool requires owner approval (it is not executed here).
    - `{:ok, result}` when the tool is allowed and has been executed.
    - `{:deny, reason}` when the tool is unknown.
  """
  @spec dispatch(Request.t(), ReyCode.RuntimeConfig.t()) :: decision()
  def dispatch(%Request{} = request, policy) do
    case VerifiedChangeBoundary.validate_request(request) do
      {:ok, request} ->
        request = with_policy_roots(request, policy)

        case authorization(request, request.workspace, policy.tools.permissions) do
          :allow -> {:ok, execute(request, policy)}
          :ask -> {:ask, request}
          :denied -> {:deny, denial_reason(request, request.workspace, policy.tools.permissions)}
        end

      {:error, reason} ->
        {:deny, reason}
    end
  end

  @doc "Executes a previously approved (or allow-listed) tool request under frozen policy."
  @spec execute(Request.t(), ReyCode.RuntimeConfig.t()) :: Result.t()
  def execute(%Request{} = request, policy) do
    result =
      case VerifiedChangeBoundary.validate_request(request) do
        {:ok, request} -> execute_validated(request, policy)
        {:error, reason} -> Result.error(reason)
      end

    # Scoped failures must remain encodable in the durable ToolRun event even
    # when an adapter returns a structured filesystem/argument error.
    if request.verified_workspace != nil and result.ok == false,
      do: %{result | error: inspect(result.error)},
      else: result
  end

  defp execute_validated(request, policy) do
    request = with_policy_roots(request, policy)

    case Permissions.bind_target(policy.tools.permissions, request) do
      {:ok, request} -> execute_bound(request, policy)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute_bound(request, policy) do
    case authorization(request, request.workspace, policy.tools.permissions) do
      :denied -> Result.error(denial_reason(request, request.workspace, policy.tools.permissions))
      _authorized -> execute_adapter(request, policy)
    end
  end

  defp execute_adapter(request, policy) do
    name = to_string(request.tool)

    case Map.fetch(@tools, name) do
      {:ok, module} -> module.run(request, policy: tool_policy(policy, name))
      :error -> Result.error(:unknown_tool)
    end
  end

  defp with_policy_roots(%Request{roots: roots} = request, _policy)
       when is_list(roots) and roots != [],
       do: request

  defp with_policy_roots(request, policy),
    do: %{request | roots: Workspace.roots(policy.workspace)}

  defp tool_policy(config, "bash"), do: config.tools.bash
  defp tool_policy(config, "artifact_read"), do: config.artifacts
  defp tool_policy(config, "read"), do: config.tools.read
  defp tool_policy(config, "edit"), do: config.tools.edit
  defp tool_policy(config, "write"), do: config.tools.write
  defp tool_policy(config, "glob"), do: config.tools.glob
  defp tool_policy(config, "list"), do: config.tools.list
  defp tool_policy(config, "grep"), do: config.tools.grep
  defp tool_policy(config, "lsp"), do: config.tools.lsp
  defp tool_policy(config, "process"), do: config.tools.process
  defp tool_policy(config, "git"), do: config.tools.bash
  defp tool_policy(config, "debug"), do: config.tools.debugger
  defp tool_policy(config, "eval"), do: config.tools.evaluation
  defp tool_policy(config, "web_search"), do: config.tools.research
  defp tool_policy(config, "read_url"), do: config.tools.research
  defp tool_policy(config, "memory"), do: config.tools.evaluation

  @doc "Returns the fail-closed authorization for a tool call in one Workspace."
  @spec authorization(Request.t() | map(), String.t()) :: :allow | :ask | :denied
  def authorization(call, workspace, permissions \\ %Permissions{})

  def authorization(%Request{verified_workspace: root} = request, workspace, permissions)
      when not is_nil(root) do
    case VerifiedChangeBoundary.validate_request(request) do
      {:ok, request} -> Permissions.decide(permissions, request, workspace)
      {:error, _reason} -> :denied
    end
  end

  def authorization(%{tool: tool} = call, workspace, permissions) do
    name = to_string(tool)

    if Map.has_key?(@tools, name),
      do: Permissions.decide(permissions, call, workspace),
      else: :denied
  end

  @doc "Distinguishes unsupported tools from configured permission denials."
  def denial_reason(%{tool: tool} = call, workspace, permissions),
    do:
      if(Map.has_key?(@tools, to_string(tool)),
        do: Permissions.denial_reason(permissions, call, workspace),
        else: :unknown_tool
      )

  @orchestration_tools MapSet.new([
                         "ask_operator",
                         "send_peer",
                         "spawn_task",
                         "spawn_tasks",
                         "update_plan"
                       ])

  @doc "Tools that route through the engine lifecycle instead of the workspace sandbox."
  @spec orchestration_tool_names() :: [String.t()]
  def orchestration_tool_names, do: @orchestration_tools |> MapSet.to_list() |> Enum.sort()

  @doc """
  Every tool name advertised on outgoing provider requests: workspace-sandbox
  tools plus orchestration tools. Orchestration tools are never executable via
  `dispatch/2` or `execute/2` — the engine claims them before the registry is
  consulted.
  """
  @spec wire_tool_names() :: [String.t()]
  def wire_tool_names, do: tool_names() ++ orchestration_tool_names()

  @doc "The set of registered workspace-sandbox tool names."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tools |> Map.keys() |> Enum.sort()
end
