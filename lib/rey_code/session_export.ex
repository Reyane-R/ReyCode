defmodule ReyCode.SessionExport do
  @moduledoc "Deterministically renders one durable Session Projection as Markdown or HTML."

  alias ReyCode.Orchestration.Projection

  @max_export_bytes 10_000_000

  @type format :: :markdown | :html

  @doc "Renders one Session without mutating Projection or EventStore state."
  @spec render(Projection.t(), String.t(), format()) :: {:ok, String.t()} | {:error, atom()}
  def render(%Projection{} = projection, session_id, format) when format in [:markdown, :html] do
    case projection.sessions[session_id] do
      nil -> {:error, :session_not_found}
      session -> session |> document(projection, format) |> bounded()
    end
  end

  @doc "Writes one deterministic Session export to an explicit path."
  @spec write(Projection.t(), String.t(), Path.t(), format()) :: :ok | {:error, term()}
  def write(projection, session_id, path, format) do
    with {:ok, content} <- render(projection, session_id, format),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content, [:binary])
    end
  end

  defp document(session, projection, :markdown) do
    header = [
      "# ",
      session.title,
      "\n\n",
      "- Session: `",
      session.id,
      "`\n- Workspace: `",
      session.workspace,
      "`\n",
      parent_markdown(session),
      "\n"
    ]

    [header | Enum.map(messages(session, projection), &message_markdown(&1, projection))]
    |> IO.iodata_to_binary()
  end

  defp document(session, projection, :html) do
    body = Enum.map(messages(session, projection), &message_html(&1, projection))

    [
      "<!doctype html><html><head><meta charset=\"utf-8\"><title>",
      html(session.title),
      "</title><style>",
      "body{max-width:900px;margin:2rem auto;font:16px system-ui;line-height:1.5}",
      "article{border-top:1px solid #ccc;padding:1rem 0}pre{white-space:pre-wrap}",
      "code{background:#eee;padding:.1rem .3rem}</style></head><body><h1>",
      html(session.title),
      "</h1><p><code>",
      html(session.id),
      "</code> · <code>",
      html(session.workspace),
      "</code></p>",
      parent_html(session),
      body,
      "</body></html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp messages(session, projection) do
    session.message_order
    |> Enum.reverse()
    |> Enum.map(&projection.messages[&1])
  end

  defp message_markdown(message, projection) do
    [
      "## ",
      message.author.name,
      "\n\n",
      message.body || "",
      "\n\n",
      tool_markdown(message, projection)
    ]
  end

  defp tool_markdown(%{invocation_id: nil}, _projection), do: ""

  defp tool_markdown(message, projection) do
    invocation = projection.invocations[message.invocation_id]

    if invocation do
      rows =
        Enum.map(invocation.tool_run_order, fn run_id ->
          run = invocation.tool_runs[run_id]
          ["- `", to_string(run.tool), "` — ", to_string(run.status), "\n"]
        end)

      if rows == [], do: "", else: ["### Tool runs\n\n", rows, "\n"]
    else
      ""
    end
  end

  defp message_html(message, projection) do
    [
      "<article><h2>",
      html(message.author.name),
      "</h2><pre>",
      html(message.body || ""),
      "</pre>",
      tool_html(message, projection),
      "</article>"
    ]
  end

  defp tool_html(%{invocation_id: nil}, _projection), do: ""

  defp tool_html(message, projection) do
    invocation = projection.invocations[message.invocation_id]

    if invocation && invocation.tool_run_order != [] do
      rows =
        Enum.map(invocation.tool_run_order, fn run_id ->
          run = invocation.tool_runs[run_id]

          [
            "<li><code>",
            html(to_string(run.tool)),
            "</code> — ",
            html(to_string(run.status)),
            "</li>"
          ]
        end)

      ["<h3>Tool runs</h3><ul>", rows, "</ul>"]
    else
      ""
    end
  end

  defp parent_markdown(%{parent_session_id: nil}), do: ""

  defp parent_markdown(session),
    do:
      "- Forked from `#{session.parent_session_id}` at sequence #{session.forked_from_sequence}\n"

  defp parent_html(%{parent_session_id: nil}), do: ""

  defp parent_html(session) do
    [
      "<p>Forked from <code>",
      html(session.parent_session_id),
      "</code> at sequence ",
      Integer.to_string(session.forked_from_sequence),
      "</p>"
    ]
  end

  defp bounded(content) when byte_size(content) <= @max_export_bytes, do: {:ok, content}
  defp bounded(_content), do: {:error, :export_too_large}

  defp html(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
