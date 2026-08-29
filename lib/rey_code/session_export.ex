defmodule ReyCode.SessionExport do
  @moduledoc "Deterministically renders one durable Session Projection as Markdown or HTML."

  alias ReyCode.Memory.Store
  alias ReyCode.Orchestration.Projection
  alias ReyCode.Provider.TextBuffer

  @max_export_bytes 10_000_000
  @max_decision_count 50
  @max_argument_bytes 200
  @max_decision_value_bytes 2_048

  @type format :: :markdown | :html

  @doc "Renders one Session and supplied decision memories without mutating either."
  @spec render(Projection.t(), String.t(), format(), [Store.memory()]) ::
          {:ok, String.t()} | {:error, atom()}
  def render(%Projection{} = projection, session_id, format, decisions \\ [])
      when format in [:markdown, :html] do
    case projection.sessions[session_id] do
      nil -> {:error, :session_not_found}
      session -> session |> document(projection, format, decisions) |> bounded()
    end
  end

  @doc "Writes one deterministic Session export to an explicit path."
  @spec write(Projection.t(), String.t(), Path.t(), format()) :: :ok | {:error, term()}
  def write(projection, session_id, path, format) do
    session = projection.sessions[session_id]
    decisions = if session, do: decisions(session.workspace), else: []

    with {:ok, content} <- render(projection, session_id, format, decisions),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content, [:binary])
    end
  end

  defp document(session, projection, :markdown, decisions) do
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

    [
      header,
      decisions_markdown(decisions)
      | Enum.map(messages(session, projection), &message_markdown(&1, projection))
    ]
    |> IO.iodata_to_binary()
  end

  defp document(session, projection, :html, decisions) do
    body = [
      decisions_html(decisions)
      | Enum.map(messages(session, projection), &message_html(&1, projection))
    ]

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

          [
            "- `",
            to_string(run.tool),
            "` — ",
            to_string(run.status),
            tool_arguments_markdown(run),
            "\n"
          ]
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
            html(tool_arguments_html(run)),
            "</li>"
          ]
        end)

      ["<h3>Tool runs</h3><ul>", rows, "</ul>"]
    else
      ""
    end
  end

  defp decisions(workspace) do
    case Process.whereis(Store) do
      nil ->
        []

      _pid ->
        case Store.list(workspace, ~w(decision assumption), @max_decision_count) do
          {:ok, entries} -> Enum.filter(entries, & &1.active)
          {:error, _reason} -> []
        end
    end
  end

  defp decisions_markdown([]), do: ""

  defp decisions_markdown(entries) do
    rows =
      Enum.map(entries, fn entry ->
        [
          "- **",
          entry.kind,
          "** `",
          entry.key,
          "` — ",
          decision_value(entry),
          " (",
          entry.created_at,
          ")\n"
        ]
      end)

    ["## Decisions & assumptions\n\n", rows, "\n"]
  end

  defp decisions_html([]), do: ""

  defp decisions_html(entries) do
    rows =
      Enum.map(entries, fn entry ->
        [
          "<li><strong>",
          html(entry.kind),
          "</strong> <code>",
          html(entry.key),
          "</code> — ",
          html(decision_value(entry)),
          " (",
          html(entry.created_at),
          ")</li>"
        ]
      end)

    ["<section><h2>Decisions &amp; assumptions</h2><ul>", rows, "</ul></section>"]
  end

  defp decision_value(entry) do
    value =
      case Jason.decode(entry.value) do
        {:ok, decoded} when is_map(decoded) ->
          [decoded["statement"], rationale(decoded["rationale"]), evidence(decoded["evidence"])]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" · ")

        _raw ->
          entry.value
      end

    TextBuffer.truncate_utf8(value, @max_decision_value_bytes)
  end

  defp rationale(nil), do: nil
  defp rationale(value), do: "because #{value}"
  defp evidence(nil), do: nil
  defp evidence(value), do: "evidence #{value}"

  defp tool_arguments_markdown(run) do
    case tool_arguments_text(run) do
      "" -> ""
      text -> " · args `#{text}`"
    end
  end

  defp tool_arguments_html(run) do
    case tool_arguments_text(run) do
      "" -> ""
      text -> " · args #{text}"
    end
  end

  defp tool_arguments_text(%{arguments: arguments}) when map_size(arguments) > 0 do
    arguments
    |> Jason.encode!()
    |> TextBuffer.truncate_utf8(@max_argument_bytes)
  end

  defp tool_arguments_text(_run), do: ""

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
