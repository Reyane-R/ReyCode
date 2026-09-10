defmodule ReyCode.Orchestration.VerifiedChangeContext do
  @moduledoc """
  Renders the durable verified-change contract outside compactable history.

  Validated records bound allocation; the goal and commands are never truncated.
  Evidence output and errors are explicitly marked previews, bounded to 256 bytes.
  Admission uses the transcript budget's four-byte token estimate as a contract
  ceiling, not as a guarantee that the entire provider request fits that budget.
  """

  alias ReyCode.Orchestration.VerifiedChange
  alias ReyCode.Provider.TextBuffer

  @doc "Returns the complete frozen contract and bounded current evidence."
  @spec prompt(VerifiedChange.t()) :: String.t()
  def prompt(record) do
    "Implement the frozen verified-change contract below. Do not run checks, Git, shell, background processes or delegate. " <>
      "Edit only this worktree. The harness alone verifies. Baseline failures are context, not permission to change the checks.\n" <>
      Jason.encode!(%{
        id: record.id,
        phase: record.phase,
        prompt: record.prompt,
        source_workspace: record.source_workspace,
        workspace: record.workspace,
        base_commit: record.base_commit,
        commands: record.commands,
        max_repair_count: record.max_repair_count,
        repair_count: record.repair_count,
        timeout_ms: record.timeout_ms,
        check_timeout_ms: record.check_timeout_ms,
        baseline: reports(record.baseline),
        checks: reports(record.checks),
        analysis: analysis_excerpt(record)
      })
  end

  @doc """
  Returns the bounded report-only analysis prompt for the Testing stage.

  The stage sees immutable check evidence and the contract only; it has no
  tools and cannot run checks, edit files, or alter the frozen contract. Its
  report is advisory: the harness alone decides whether checks passed.
  """
  @spec analysis_prompt(VerifiedChange.t()) :: String.t()
  def analysis_prompt(record) do
    "Analyze the failed verification evidence below and report findings for the implementing assistant. " <>
      "You are report-only: respond with text only. Do not run checks, edit files, use tools, or claim success. " <>
      "Report which checks failed, likely causes tied to command_index, and what the repair should focus on.\n" <>
      Jason.encode!(%{
        id: record.id,
        goal: record.prompt,
        commands: record.commands,
        repair_count: record.repair_count,
        max_repair_count: record.max_repair_count,
        baseline: reports(record.baseline),
        checks: reports(record.checks)
      })
  end

  @doc """
  Returns the bounded report-only release-metadata prompt for the Release stage.

  The stage drafts commit and pull-request text from the verified evidence. It
  has no tools and cannot modify the candidate; its draft is advisory until the
  Owner authorizes any release operation.
  """
  @spec release_prompt(VerifiedChange.t()) :: String.t()
  def release_prompt(record) do
    "Draft release metadata for the verified change below. " <>
      "You are report-only: respond with text only. Do not use tools or modify files. " <>
      "Include a commit subject line, a commit body, a pull-request title, and a pull-request description.\n" <>
      Jason.encode!(%{
        id: record.id,
        goal: record.prompt,
        patch_bytes: byte_size(record.patch),
        commands: record.commands,
        checks: reports(record.checks)
      })
  end

  @doc "Rejects oversized contracts before a Turn is queued; retry with a larger context budget."
  @spec admit(VerifiedChange.t() | nil, pos_integer()) :: :ok | {:error, String.t()}
  def admit(nil, _context_budget_tokens), do: :ok

  def admit(record, context_budget_tokens) do
    contract_bytes = byte_size(prompt(record))
    budget_bytes = context_budget_tokens * 4

    if contract_bytes <= budget_bytes do
      :ok
    else
      {:error,
       "Verified-change contract requires #{contract_bytes} bytes but context_budget_tokens permits " <>
         "#{budget_bytes} bytes; increase context_budget_tokens to at least #{div(contract_bytes + 3, 4)} " <>
         "or start a new verified change with a shorter goal/check contract. The frozen contract was not truncated."}
    end
  end

  # Repair turns receive the bounded advisory analysis from the report-only
  # Testing stage; implementation turns never see a stale report.
  defp analysis_excerpt(%{phase: "repairing", analysis: %{"response" => _} = analysis}),
    do: %{
      "outcome" => analysis["outcome"],
      "response" => TextBuffer.truncate_utf8(analysis["response"], 2048)
    }

  defp analysis_excerpt(_record), do: nil

  defp reports(reports) do
    reports
    |> Enum.with_index(1)
    |> Enum.map(fn {report, index} ->
      report
      |> Map.delete("command")
      |> Map.put("command_index", index)
      |> Map.put("output", TextBuffer.truncate_utf8(report["output"], 256))
      |> Map.put("output_is_preview", byte_size(report["output"]) > 256)
      |> Map.put("error", report["error"] && TextBuffer.truncate_utf8(report["error"], 256))
      |> Map.put("error_is_preview", byte_size(report["error"] || "") > 256)
    end)
  end
end
