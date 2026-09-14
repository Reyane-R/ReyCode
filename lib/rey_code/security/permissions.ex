defmodule ReyCode.Security.Permissions do
  @moduledoc "Validated, ordered tool permissions; the last matching rule wins."

  alias ReyCode.Security.{ApprovalRules, CanonicalPath}

  defmodule Rule do
    @moduledoc "One ordered permission rule for an executable tool."
    @enforce_keys [:tool, :action]
    defstruct [:tool, :action, :pattern]

    @type t :: %__MODULE__{
            tool: String.t(),
            action: :allow | :ask | :deny,
            pattern: String.t() | nil
          }
  end

  defstruct default: :allow, rules: []
  @type t :: %__MODULE__{default: :allow | :ask | :deny, rules: [Rule.t()]}
  @actions [:allow, :ask, :deny]
  @max_rules_count 128
  @max_pattern_bytes 512
  @max_input_bytes 128_000
  @max_match_steps 1_000_000
  @path_tools ["read", "write", "edit", "glob", "list", "grep"]

  @doc "Binds patterned file requests to the identity checked immediately before execution."
  def bind_target(policy, request) do
    patterned? =
      Enum.any?(policy.rules, &(Map.get(&1, :pattern) != nil and &1.tool == request.tool))

    if request.tool in @path_tools and patterned? do
      value = Map.get(request.arguments, "path", Map.get(request.arguments, :path))

      with true <- is_binary(value) and byte_size(value) <= @max_input_bytes,
           {:ok, root} <- CanonicalPath.resolve_identity(request.workspace),
           {:ok, path} <- CanonicalPath.resolve_identity(Path.expand(value, root)) do
        {:ok,
         %{request | arguments: request.arguments |> Map.delete(:path) |> Map.put("path", path)}}
      else
        _ -> {:error, :permission_path_unresolved}
      end
    else
      {:ok, request}
    end
  end

  @spec new!(map()) :: t()
  def new!(value) do
    with %{default: default, rules: rules} <- value,
         true <- map_size(value) == 2 and default in @actions,
         true <- is_list(rules) and length(rules) <= @max_rules_count,
         true <- Enum.all?(rules, &valid_rule?/1) do
      %__MODULE__{default: default, rules: Enum.map(rules, &struct!(Rule, &1))}
    else
      _ ->
        raise ArgumentError,
              "invalid tool_permissions: expected default allow/ask/deny and at most 128 rules with tool, action, and optional pattern"
    end
  end

  @spec decide(t(), map(), String.t()) :: :allow | :ask | :denied
  def decide(policy, call, workspace) do
    case action(policy, call, workspace) do
      :deny -> :denied
      {:error, _reason} -> :denied
      :ask -> if ApprovalRules.allows?(workspace, call), do: :allow, else: :ask
      :allow -> :allow
    end
  end

  @doc "Explains a denial without exposing tool arguments."
  def denial_reason(policy, call, workspace) do
    case action(policy, call, workspace) do
      {:error, reason} -> reason
      _action -> :permission_denied
    end
  end

  defp action(policy, call, workspace) do
    Enum.reduce_while(policy.rules, policy.default, fn rule, action ->
      case matches?(rule, call, workspace) do
        true -> {:cont, rule.action}
        false -> {:cont, action}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_rule?(%{tool: tool, action: action} = rule) do
    is_binary(tool) and (tool == "*" or tool in ReyCode.ToolRegistry.tool_names()) and
      action in @actions and
      Map.keys(rule) -- [:tool, :action, :pattern] == [] and
      valid_pattern?(Map.get(rule, :pattern, "*")) and patterned_tool?(rule)
  end

  defp valid_rule?(_), do: false

  defp patterned_tool?(%{tool: tool, pattern: _pattern}),
    do: tool in ["bash" | @path_tools]

  defp patterned_tool?(_rule), do: true

  defp valid_pattern?(pattern),
    do:
      is_binary(pattern) and byte_size(pattern) in 1..@max_pattern_bytes and
        String.valid?(pattern)

  defp matches?(rule, call, workspace) do
    tool = to_string(call.tool)

    if rule.tool == "*" or rule.tool == tool,
      do: input_matches?(rule, tool, call.arguments, workspace),
      else: false
  end

  defp input_matches?(%{pattern: pattern}, tool, arguments, workspace) when is_binary(pattern) do
    key = if tool == "bash", do: :command, else: :path
    value = Map.get(arguments, Atom.to_string(key), Map.get(arguments, key))

    with true <-
           is_binary(value) and byte_size(value) <= @max_input_bytes and String.valid?(value),
         {:ok, value} <- match_input(tool, value, workspace, pattern) do
      wildcard(String.to_charlist(pattern), String.to_charlist(value), nil, @max_match_steps)
    else
      false -> {:error, :permission_input_invalid}
      {:error, _reason} -> {:error, :permission_path_unresolved}
    end
  end

  defp input_matches?(_rule, _tool, _arguments, _workspace), do: true

  defp match_input("bash", value, _workspace, _pattern), do: {:ok, value}

  defp match_input(_tool, value, workspace, pattern) do
    with {:ok, root} <- CanonicalPath.resolve_identity(workspace),
         {:ok, path} <- CanonicalPath.resolve_identity(Path.expand(value, root)) do
      {:ok, if(Path.type(pattern) == :absolute, do: path, else: Path.relative_to(path, root))}
    end
  end

  # A bounded glob walk avoids regex backtracking failures becoming nonmatches.
  # Exhaustion is a denial, never a fallback to an earlier allow rule.
  defp wildcard(_pattern, _input, _star, 0), do: {:error, :permission_match_limit}
  defp wildcard([], [], _star, _steps), do: true

  defp wildcard([?* | pattern], input, _star, steps),
    do: wildcard(pattern, input, {pattern, input}, steps - 1)

  defp wildcard([char | pattern], [char | input], star, steps),
    do: wildcard(pattern, input, star, steps - 1)

  defp wildcard([?? | pattern], [_char | input], star, steps),
    do: wildcard(pattern, input, star, steps - 1)

  defp wildcard(_pattern, _input, {pattern, [_char | input]}, steps),
    do: wildcard(pattern, input, {pattern, input}, steps - 1)

  defp wildcard(_pattern, _input, _star, _steps), do: false
end
