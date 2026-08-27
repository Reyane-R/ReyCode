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

  alias ReyCode.Tool.{
    BackgroundProcess,
    Debug,
    Git,
    LSP,
    Memory,
    Request,
    Result
  }

  @tools %{
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
        if requires_approval?(request) do
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

  defp with_policy_roots(%Request{roots: roots} = request, _policy)
       when is_list(roots) and roots != [],
       do: request

  defp with_policy_roots(request, policy),
    do: %{request | roots: Workspace.roots(policy.workspace)}

  defp tool_policy(config, "bash"), do: config.tools.bash
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

  def requires_approval?(%Request{tool: tool, arguments: arguments}),
    do: approval_required?(tool, arguments)

  def requires_approval?(%{tool: tool, arguments: arguments}),
    do: approval_required?(tool, arguments)

  def requires_approval?(tool), do: MapSet.member?(@ask_tools, to_string(tool))

  defp approval_required?(tool, arguments) do
    MapSet.member?(@ask_tools, to_string(tool)) or
      lsp_mutation?(tool, arguments) or process_mutation?(tool, arguments) or
      git_mutation?(tool, arguments) or debug_mutation?(tool, arguments) or
      eval_mutation?(tool, arguments) or memory_mutation?(tool, arguments)
  end

  defp lsp_mutation?(tool, arguments) when tool in [:lsp, "lsp"] and is_map(arguments) do
    action = Map.get(arguments, "action", Map.get(arguments, :action))
    LSP.mutating_action?(action)
  end

  defp lsp_mutation?(_tool, _arguments), do: false

  defp process_mutation?(tool, arguments)
       when tool in [:process, "process"] and is_map(arguments) do
    action = Map.get(arguments, "action", Map.get(arguments, :action))
    BackgroundProcess.mutating_action?(action)
  end

  defp process_mutation?(_tool, _arguments), do: false

  defp git_mutation?(tool, arguments) when tool in [:git, "git"] and is_map(arguments) do
    action = Map.get(arguments, "action", Map.get(arguments, :action))
    Git.mutating_action?(action)
  end

  defp git_mutation?(_tool, _arguments), do: false

  defp debug_mutation?(tool, arguments) when tool in [:debug, "debug"] and is_map(arguments) do
    action = Map.get(arguments, "action", Map.get(arguments, :action))
    Debug.mutating_action?(action)
  end

  defp debug_mutation?(_tool, _arguments), do: false

  defp eval_mutation?(tool, _arguments) when tool in [:eval, "eval"], do: true
  defp eval_mutation?(_tool, _arguments), do: false

  defp memory_mutation?(tool, arguments) when tool in [:memory, "memory"] and is_map(arguments) do
    action = Map.get(arguments, "action", Map.get(arguments, :action))
    Memory.mutating_action?(action)
  end

  defp memory_mutation?(_tool, _arguments), do: false

  @orchestration_tools MapSet.new(["spawn_task"])

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
