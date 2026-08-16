defmodule ReyCode.CredoChecks.ListBracketAccess do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Elixir lists do not support bracket-index access (`mylist[0]`).
      Use `Enum.at/2`, pattern matching, or `List` functions instead.

          # BAD
          first = mylist[0]

          # GOOD
          first = Enum.at(mylist, 0)
          # or
          [first | _] = mylist
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse(
         {{:., meta, [Access, :get]}, _, [{_var, _, ctx}, key]} = ast,
         issues,
         issue_meta
       )
       when is_integer(key) and is_atom(ctx) do
    if from_brackets?(meta) do
      {ast, issues ++ [issue_for(meta, issue_meta)]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp from_brackets?(meta), do: Keyword.get(meta, :from_brackets) == true

  defp issue_for(meta, issue_meta) do
    format_issue(issue_meta,
      message: "Lists do not support bracket-index access — use `Enum.at/2` instead.",
      trigger: "[]",
      line_no: meta[:line]
    )
  end
end
