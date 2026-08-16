defmodule ReyCode.CredoChecks.StructBracketAccess do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [struct_vars: ~w(event frame struct changeset cs)],
    explanations: [
      check: """
      Structs do not implement the `Access` behaviour, so bracket access
      (`struct[:field]`) raises at runtime. Access fields directly instead.

          # BAD
          value = state[:field]

          # GOOD
          value = state.field
      """,
      params: [
        struct_vars:
          "Variable names known to hold structs (defaults to ~w(changeset cs struct record state invocation turn room event frame))"
      ]
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    struct_vars = Params.get(params, :struct_vars, __MODULE__)
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, struct_vars, issue_meta))
  end

  defp traverse(
         {{:., _meta, [Access, :get]}, _, [{:assigns, _, _}, _key]} = ast,
         issues,
         _struct_vars,
         _issue_meta
       ) do
    {ast, issues}
  end

  defp traverse(
         {{:., meta, [Access, :get]}, _, [{var_name, _, ctx}, _key]} = ast,
         issues,
         struct_vars,
         issue_meta
       )
       when is_atom(var_name) and is_atom(ctx) do
    if from_brackets?(meta) and Atom.to_string(var_name) in struct_vars do
      {ast, issues ++ [issue_for(var_name, meta, issue_meta)]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _struct_vars, _issue_meta) do
    {ast, issues}
  end

  defp from_brackets?(meta), do: Keyword.get(meta, :from_brackets) == true

  defp issue_for(var_name, meta, issue_meta) do
    format_issue(issue_meta,
      message: "`#{var_name}[:field]` fails on structs — use `#{var_name}.field` instead.",
      trigger: "#{var_name}[",
      line_no: meta[:line]
    )
  end
end
