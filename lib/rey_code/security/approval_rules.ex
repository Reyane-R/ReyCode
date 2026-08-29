defmodule ReyCode.Security.ApprovalRules do
  @moduledoc """
  Loads the Workspace-owned allow rules for commands that normally require approval.

  Rules live at `.reycode/approval_rules.json`. Only Bash commands are supported;
  unknown, malformed, oversized, or symlinked files fail closed. A rule is either
  an exact command or a single trailing ` *` prefix wildcard.
  """

  @relative_path ".reycode/approval_rules.json"
  @max_file_bytes 16_384
  @max_rule_count 32
  @max_rule_bytes 256
  @max_command_bytes 8_192
  @unsafe_shell_fragments [";", "&", "|", "`", "$", "(", ")", "<", ">", "\n", "\r"]

  @type load_error ::
          :missing
          | :not_regular
          | :too_large
          | :invalid_json
          | :invalid_schema
          | File.posix()

  @doc "Returns whether a Workspace rule explicitly allows the tool call."
  @spec allows?(String.t(), map()) :: boolean()
  def allows?(workspace, %{tool: tool, arguments: arguments})
      when tool in [:bash, "bash"] and is_map(arguments) do
    command = Map.get(arguments, :command, Map.get(arguments, "command"))

    with true <- is_binary(command),
         true <- byte_size(command) <= @max_command_bytes,
         false <- unsafe_command?(command),
         {:ok, patterns} <- load(workspace) do
      Enum.any?(patterns, &matches?(&1, String.trim(command)))
    else
      _other -> false
    end
  end

  def allows?(_workspace, _call), do: false

  @doc "Loads and validates Bash allow patterns from the Workspace rule file."
  @spec load(String.t()) :: {:ok, [String.t()]} | {:error, load_error()}
  def load(workspace) when is_binary(workspace) do
    path = Path.join(Path.expand(workspace), @relative_path)

    with {:ok, %{type: :regular, size: size}} when size <= @max_file_bytes <- File.lstat(path),
         {:ok, encoded} <- read_bounded(path),
         {:ok, document} <- Jason.decode(encoded),
         {:ok, patterns} <- validate(document) do
      {:ok, patterns}
    else
      {:error, :enoent} -> {:error, :missing}
      {:ok, %{type: :regular}} -> {:error, :too_large}
      {:ok, _stat} -> {:error, :not_regular}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(_workspace), do: {:error, :invalid_schema}

  defp read_bounded(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, @max_file_bytes + 1) end) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, encoded} when byte_size(encoded) <= @max_file_bytes -> {:ok, encoded}
      {:ok, _encoded} -> {:error, :too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate(%{"version" => 1, "allow" => %{"bash" => patterns}} = document)
       when map_size(document) == 2 and is_list(patterns) and length(patterns) <= @max_rule_count do
    if Enum.all?(patterns, &valid_pattern?/1),
      do: {:ok, patterns},
      else: {:error, :invalid_schema}
  end

  defp validate(_document), do: {:error, :invalid_schema}

  defp valid_pattern?(pattern) when is_binary(pattern) do
    pattern == String.trim(pattern) and pattern != "" and byte_size(pattern) <= @max_rule_bytes and
      not unsafe_command?(pattern) and valid_wildcard?(pattern)
  end

  defp valid_pattern?(_pattern), do: false

  defp valid_wildcard?(pattern) do
    case :binary.matches(pattern, "*") do
      [] -> true
      [{index, 1}] -> index == byte_size(pattern) - 1 and String.ends_with?(pattern, " *")
      _multiple -> false
    end
  end

  defp matches?(pattern, command) do
    if String.ends_with?(pattern, " *") do
      base = binary_part(pattern, 0, byte_size(pattern) - 2)
      command == base or String.starts_with?(command, base <> " ")
    else
      command == pattern
    end
  end

  defp unsafe_command?(command),
    do: Enum.any?(@unsafe_shell_fragments, &(:binary.match(command, &1) != :nomatch))
end
