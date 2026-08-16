defmodule ReyCode.CredoChecks.RequireHttpTimeout do
  @moduledoc false
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Every `:httpc.request/4` or `:httpc.request/5` call must set a `timeout`
      in its HTTP options so a hung peer cannot stall the process indefinitely.

          # BAD — no bounded timeout
          :httpc.request(:post, request, [ssl: ssl_opts()], opts)

          # GOOD
          :httpc.request(:post, request, [ssl: ssl_opts(), timeout: 30_000], opts)
      """
    ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # :httpc.request/4 or /5 — the third argument is http_opts (a keyword list).
  # Flag when http_opts is an inline keyword list that does not contain :timeout.
  defp traverse(
         {{:., meta, [:httpc, :request]}, _, [_method, _request, http_opts | _rest]} = ast,
         issues,
         issue_meta
       ) do
    if inline_keyword?(http_opts) and not has_timeout?(http_opts) do
      {ast, issues ++ [issue_for(meta, issue_meta)]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp inline_keyword?(list), do: is_list(list) and list != [] and Keyword.keyword?(list)

  defp has_timeout?(ast), do: contains?(ast, &match?({:timeout, _}, &1))

  defp contains?(node, predicate) do
    predicate.(node) ||
      case node do
        {_, _, inner} when is_list(inner) -> Enum.any?(inner, &contains?(&1, predicate))
        list when is_list(list) -> Enum.any?(list, &contains?(&1, predicate))
        _ -> false
      end
  end

  defp issue_for(meta, issue_meta) do
    format_issue(issue_meta,
      message:
        ":httpc.request must set a `timeout` in its HTTP options so a hung peer can't stall the process.",
      line_no: meta[:line]
    )
  end
end
