defmodule ReyCode.CredoChecks.StringToAtom do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      `String.to_atom/1` is unsafe on untrusted input — atoms are never
      garbage collected, so dynamic atom creation can exhaust memory.

          # BAD
          String.to_atom(user_input)

          # GOOD
          String.to_existing_atom(user_input)
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({:., meta, [{:__aliases__, _, [:String]}, :to_atom]} = ast, issues, issue_meta) do
    {ast, issues ++ [issue_for(meta, issue_meta)]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(meta, issue_meta) do
    format_issue(issue_meta,
      message:
        "Avoid `String.to_atom/1` — use `String.to_existing_atom/1` to prevent memory leaks.",
      trigger: "String.to_atom",
      line_no: meta[:line]
    )
  end
end
