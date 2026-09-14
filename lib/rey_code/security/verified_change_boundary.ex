defmodule ReyCode.Security.VerifiedChangeBoundary do
  @moduledoc """
  Restricts provider tools using the current persisted Session contract.

  Claim and start must both consult the projection; approval never overrides
  this policy. Scoped requests repeat filesystem checks immediately before
  dispatch. Existing tool containment remains responsible for ordinary paths.
  Multiply-linked mutation targets fail closed because other aliases cannot
  be proven local with a bounded lookup. Ignored untracked files cannot enter
  the verified patch, so they and Git ignore/attribute controls are immutable
  to providers. Git lookup failures deny mutations. Recovery owns interrupted
  Sessions.
  """

  alias ReyCode.Orchestration.{Session, ToolRun, VerifiedChange}
  alias ReyCode.Provider.Command
  alias ReyCode.Security.{CanonicalPath, Environment, Workspace}
  alias ReyCode.Tool.{Request, Support}

  @allowed ~w(read edit write grep glob list ask_operator update_plan)
  @git_lookup_timeout_ms 2_000
  @git_lookup_max_output_bytes 4_096

  @spec tool_names(Session.t()) :: [String.t()] | nil
  def tool_names(%Session{verified_change: nil}), do: nil

  def tool_names(%Session{verified_change: %VerifiedChange{phase: phase}})
      when phase in ~w(implementing repairing),
      do: @allowed

  def tool_names(%Session{}), do: []

  @spec authorize(Session.t(), map()) :: :ok | {:error, term()}
  def authorize(%Session{verified_change: nil}, _call), do: :ok

  def authorize(%Session{verified_change: %VerifiedChange{} = change} = session, call) do
    cond do
      change.phase not in ~w(implementing repairing) ->
        {:error, :verified_change_phase_forbidden}

      call.tool not in @allowed ->
        {:error, :verified_change_tool_forbidden}

      true ->
        session |> scoped_request(call) |> validate_request() |> validation_result()
    end
  end

  def authorize(%Session{}, _call), do: {:error, :invalid_verified_change}

  @spec start_request(Session.t(), ToolRun.t()) :: :ok | {:ok, Request.t()} | {:error, term()}
  def start_request(%Session{verified_change: nil}, _run), do: :ok

  def start_request(session, run) do
    with :ok <- authorize(session, run) do
      if run.authorization != :allow and run.resolution != :approve,
        do: {:error, :verified_change_approval_required},
        else: {:ok, %{scoped_request(session, run) | request_id: run.id}}
    end
  end

  @spec validate_request(Request.t()) :: {:ok, Request.t()} | {:error, term()}
  def validate_request(%Request{verified_workspace: nil} = request), do: {:ok, request}

  def validate_request(%Request{verified_workspace: root} = request) do
    with true <- request.tool in @allowed,
         {:ok, canonical} <- Workspace.validate(root, roots: [root]),
         true <- canonical == root,
         request = %{request | workspace: root, roots: [root]},
         :ok <- mutation_path(request) do
      {:ok, request}
    else
      false -> {:error, :verified_change_scope_forbidden}
      {:error, _reason} = error -> error
    end
  end

  defp scoped_request(session, call) do
    Request.new(
      tool: call.tool,
      arguments: call.arguments,
      workspace: session.verified_change.workspace,
      roots: [session.verified_change.workspace],
      verified_workspace: session.verified_change.workspace
    )
  end

  defp validation_result({:ok, _request}), do: :ok
  defp validation_result({:error, _reason} = error), do: error

  defp mutation_path(%Request{tool: tool} = request) when tool in ~w(write edit) do
    with {:ok, path} <- Support.require_arg(request.arguments, :path),
         :ok <- reject_git_path(path),
         {:ok, canonical} <- Support.within_roots(path, request),
         :ok <- reject_git_path(Path.relative_to(canonical, request.workspace)),
         :ok <- single_link(canonical) do
      snapshot_path(request.workspace, canonical)
    end
  end

  defp mutation_path(_request), do: :ok

  defp reject_git_path(path) do
    if Enum.any?(Path.split(path), &(String.downcase(&1) in ~w(.git .gitignore .gitattributes))),
      do: {:error, :verified_change_git_path_forbidden},
      else: :ok
  end

  defp snapshot_path(workspace, canonical) do
    env =
      Environment.allowlisted()
      |> Map.merge(%{
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_CEILING_DIRECTORIES" => Path.dirname(workspace)
      })

    assignments = Enum.map(env, fn {key, value} -> key <> "=" <> value end)

    # check-ignore uses literal paths and excludes tracked entries by default.
    # This built-in reads the index/ignore rules, never filters or remote helpers.
    result =
      Command.run(
        "/usr/bin/env",
        ["-i" | assignments] ++
          [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.attributesFile=/dev/null",
            "check-ignore",
            "--quiet",
            "--",
            Path.relative_to(canonical, workspace)
          ],
        cd: workspace,
        timeout_ms: @git_lookup_timeout_ms,
        max_output_bytes: @git_lookup_max_output_bytes
      )

    case result do
      {:ok, ""} -> {:error, :verified_change_ignored_path_forbidden}
      {:error, {:exit_status, 1, ""}} -> :ok
      _other -> {:error, :verified_change_git_lookup_failed}
    end
  end

  defp single_link(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, links: 1}} -> :ok
      {:ok, %File.Stat{type: :regular}} -> {:error, :verified_change_hardlink_forbidden}
      {:ok, _stat} -> {:error, :verified_change_mutation_target_forbidden}
      {:error, :enoent} -> missing_leaf(path)
      {:error, _reason} = error -> error
    end
  end

  defp missing_leaf(path) do
    case CanonicalPath.resolve_identity(path) do
      {:ok, ^path} -> :ok
      _other -> {:error, :verified_change_scope_forbidden}
    end
  end
end
