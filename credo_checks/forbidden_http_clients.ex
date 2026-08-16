defmodule ReyCode.CredoChecks.ForbiddenHttpClients do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      This project uses `:httpc` (Erlang's built-in HTTP client) for outbound
      HTTP. Do not introduce HTTPoison, Tesla, or Finch — they add unnecessary
      dependencies and diverge from the established transport boundary.

          # BAD
          HTTPoison.get(url)
          Tesla.get(url)
          Finch.request(%{method: :get, url: url}, MyFinch)

          # GOOD
          :httpc.request(:get, {url, headers}, http_opts, opts)
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  defp traverse({:__aliases__, meta, [:HTTPoison]} = ast, issues, issue_meta) do
    {ast, issues ++ [issue_for("HTTPoison", meta, issue_meta)]}
  end

  defp traverse({:__aliases__, meta, [:Tesla]} = ast, issues, issue_meta) do
    {ast, issues ++ [issue_for("Tesla", meta, issue_meta)]}
  end

  defp traverse({:__aliases__, meta, [:Finch]} = ast, issues, issue_meta) do
    {ast, issues ++ [issue_for("Finch", meta, issue_meta)]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(name, meta, issue_meta) do
    format_issue(issue_meta,
      message: "Use :httpc instead of #{name} — this project's HTTP boundary is :httpc.",
      trigger: name,
      line_no: meta[:line]
    )
  end
end
