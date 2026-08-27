defmodule ReyCode.Tool.Git do
  @moduledoc """
  Bounded, structured Git inspection and approved mutation workflows.

  Inspection never stages or writes. Commit only commits already-staged files;
  conflict resolution writes one explicitly selected file version and requires
  owner approval through the normal ToolRun gate.
  """

  @behaviour ReyCode.Tool

  alias ReyCode.Provider.Command
  alias ReyCode.RuntimeConfig.Tools.Bash, as: CommandPolicy
  alias ReyCode.Tool.{Request, Result, Support}

  @read_actions ~w(status diff log branches conflicts review)
  @write_actions ~w(commit resolve_conflict)
  @actions @read_actions ++ @write_actions
  @max_files 200

  @impl true
  def run(%Request{arguments: arguments, workspace: workspace}, opts) do
    %CommandPolicy{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, action} <- Support.require_arg(arguments, :action),
         :ok <- known_action(action) do
      execute(action, arguments, workspace, policy)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Returns true when a Git action mutates the working tree or index."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in @write_actions

  defp known_action(action) do
    if action in @actions, do: :ok, else: {:error, :unsupported_git_action}
  end

  defp execute("status", _arguments, workspace, policy) do
    case git(workspace, ["status", "--porcelain=v1", "--branch"], policy) do
      {:ok, output} ->
        entries = parse_status(output)
        Result.ok(Jason.encode!(%{"branch" => branch(entries), "files" => entries}))

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp execute("diff", arguments, workspace, policy) do
    args = ["diff", "--no-ext-diff", "--binary"] ++ diff_scope(arguments)

    case git(workspace, args, policy) do
      {:ok, output} -> Result.ok(output, truncated: byte_size(output) >= policy.max_output_bytes)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("log", arguments, workspace, policy) do
    count = integer_argument(arguments, "count", 20) |> min(100) |> max(1)

    args = [
      "log",
      "--no-decorate",
      "--format=%H%x09%an%x09%ad%x09%s",
      "--date=iso",
      "-n",
      Integer.to_string(count)
    ]

    case git(workspace, args, policy) do
      {:ok, output} -> Result.ok(output)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("branches", _arguments, workspace, policy) do
    case git(
           workspace,
           ["branch", "--no-color", "--format=%(HEAD) %(refname:short) %(objectname)"],
           policy
         ) do
      {:ok, output} -> Result.ok(output)
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("conflicts", _arguments, workspace, policy) do
    case git(workspace, ["diff", "--name-only", "--diff-filter=U"], policy) do
      {:ok, output} ->
        files = output |> String.split("\n", trim: true) |> Enum.take(@max_files)
        Result.ok(Jason.encode!(%{"files" => files, "count" => length(files)}))

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp execute("review", arguments, workspace, policy) do
    with {:ok, diff} <- git(workspace, ["diff", "--check"], policy),
         {:ok, stat} <-
           git(workspace, ["diff", "--stat", "--no-ext-diff"] ++ diff_scope(arguments), policy),
         {:ok, names} <-
           git(
             workspace,
             ["diff", "--name-status", "--no-ext-diff"] ++ diff_scope(arguments),
             policy
           ) do
      findings = whitespace_findings(diff)

      Result.ok(
        Jason.encode!(%{
          "verdict" => verdict(findings),
          "findings" => findings,
          "stat" => stat,
          "files" => names
        })
      )
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("commit", arguments, workspace, policy) do
    with {:ok, message} <- Support.require_arg(arguments, :message),
         :ok <- valid_message(message),
         {:ok, output} <- git(workspace, ["commit", "--no-verify", "-m", message], policy) do
      Result.ok(output)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp execute("resolve_conflict", arguments, workspace, policy) do
    with {:ok, path} <- Support.require_arg(arguments, :path),
         {:ok, choice} <- Support.require_arg(arguments, :choice),
         :ok <- valid_choice(choice),
         {:ok, canonical} <-
           Support.within_roots(path, %Request{
             workspace: workspace,
             roots: [workspace],
             tool: "git",
             arguments: arguments
           }),
         {:ok, output} <- git(workspace, ["checkout", "--#{choice}", "--", canonical], policy),
         {:ok, _add_output} <- git(workspace, ["add", "--", canonical], policy) do
      Result.ok(output, metadata: %{"path" => canonical, "choice" => choice})
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp git(workspace, args, policy) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      executable ->
        Command.run(executable, ["-c", "core.quotepath=false", "-c", "color.ui=false"] ++ args,
          cd: workspace,
          timeout_ms: policy.timeout_ms,
          max_output_bytes: policy.max_output_bytes,
          env: [{"GIT_OPTIONAL_LOCKS", "0"}]
        )
        |> normalize_git_result()
    end
  end

  defp normalize_git_result({:ok, output}), do: {:ok, output}

  defp normalize_git_result({:error, {:exit_status, status, output}}),
    do: {:error, {:git_exit, status, output}}

  defp normalize_git_result({:error, reason}), do: {:error, reason}

  defp parse_status(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.take(@max_files)
    |> Enum.map(fn
      "## " <> branch ->
        %{"kind" => "branch", "value" => branch}

      <<index::binary-size(1), worktree::binary-size(1), " ", path::binary>> ->
        %{"kind" => "file", "index" => index, "worktree" => worktree, "path" => path}

      line ->
        %{"kind" => "unknown", "value" => line}
    end)
  end

  defp branch(entries), do: Enum.find_value(entries, "detached", &branch_value/1)
  defp branch_value(%{"kind" => "branch", "value" => branch}), do: branch
  defp branch_value(_entry), do: nil

  defp diff_scope(arguments) do
    case Map.get(arguments, "staged", Map.get(arguments, :staged, false)) do
      true -> ["--cached"]
      "true" -> ["--cached"]
      _ -> []
    end
  end

  defp whitespace_findings(""), do: []

  defp whitespace_findings(diff) do
    [
      %{
        "priority" => "P2",
        "confidence" => 1.0,
        "message" => "Whitespace errors detected by git diff --check",
        "detail" => String.slice(diff, 0, 2_000)
      }
    ]
  end

  defp verdict([]), do: "ship"
  defp verdict(_findings), do: "review_required"

  defp valid_message(message) do
    if String.trim(message) == "", do: {:error, :empty_commit_message}, else: :ok
  end

  defp valid_choice(choice) when choice in ["ours", "theirs", "base"], do: :ok
  defp valid_choice(_choice), do: {:error, :invalid_conflict_choice}

  defp integer_argument(arguments, key, default) do
    case Map.get(arguments, key, Map.get(arguments, argument_key(key))) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end

      _ ->
        default
    end
  end

  defp argument_key("count"), do: :count
end
