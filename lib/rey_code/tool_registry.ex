defmodule ReyCode.ToolRegistry do
  @moduledoc """
  Dispatches provider tool requests to ReyCode-executed tools under a trust boundary.

  The approval model is rooted in workspace trust (D23):

    - `read`, `grep`, `glob`, `list`, `edit` are allowed inside `REYCODE_WORKSPACE_ROOTS`.
    - `bash` and `write` require owner approval (`ask`) before execution.
    - Anything outside the trusted roots is denied before any tool runs.
  """

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
  @spec dispatch(Request.t()) :: decision()
  def dispatch(%Request{} = request) do
    name = to_string(request.tool)

    case Map.fetch(@tools, name) do
      {:ok, _module} ->
        if MapSet.member?(@ask_tools, name) do
          {:ask, request}
        else
          {:ok, execute(request)}
        end

      :error ->
        {:deny, :unknown_tool}
    end
  end

  @doc "Executes a previously approved (or allow-listed) tool request."
  @spec execute(Request.t()) :: Result.t()
  def execute(%Request{} = request) do
    name = to_string(request.tool)

    case Map.fetch(@tools, name) do
      {:ok, module} -> module.run(request, [])
      :error -> Result.error(:unknown_tool)
    end
  end

  @doc "Whether a tool name requires owner approval before execution."
  @spec requires_approval?(Request.t() | String.t() | atom()) :: boolean()
  def requires_approval?(%Request{tool: tool}), do: requires_approval?(tool)
  def requires_approval?(tool), do: MapSet.member?(@ask_tools, to_string(tool))

  @doc "The set of registered tool names."
  @spec tool_names() :: [String.t()]
  def tool_names, do: @tools |> Map.keys() |> Enum.sort()
end
