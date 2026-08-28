defmodule ReyCode.TUI.MermaidASCII do
  @moduledoc "Bounded terminal rendering for Mermaid flowchart and sequence blocks."

  alias ReyCode.Provider.TextBuffer

  @source_max_bytes 65_536
  @block_max_count 8
  @edge_max_count 64
  @line_max_bytes 512
  @fence ~r/```mermaid[ \t]*\n(.*?)```/ms
  @flow_edge ~r/^(.+?)\s*(-->|---|-.->|==>)\s*(?:\|([^|]+)\|\s*)?(.+?)$/

  @doc "Replaces bounded Mermaid fences with compact ASCII diagrams."
  @spec expand(String.t()) :: String.t()
  def expand(markdown) when is_binary(markdown) do
    markdown
    |> TextBuffer.truncate_utf8(@source_max_bytes)
    |> expand_blocks(0)
  rescue
    _error -> markdown
  end

  defp expand_blocks(markdown, count) when count >= @block_max_count, do: markdown

  defp expand_blocks(markdown, count) do
    case Regex.run(@fence, markdown) do
      [full, source] ->
        markdown
        |> String.replace(full, render_block(source), global: false)
        |> expand_blocks(count + 1)

      _none ->
        markdown
    end
  end

  defp render_block(source) do
    source = TextBuffer.truncate_utf8(source, @source_max_bytes)

    lines =
      source
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&blank_or_comment?/1)

    kind = List.first(lines) || "diagram"
    body = Enum.drop(lines, 1)

    rendered =
      cond do
        String.starts_with?(kind, "sequenceDiagram") ->
          sequence_lines(body)

        String.starts_with?(kind, "flowchart") or String.starts_with?(kind, "graph") ->
          flow_lines(body)

        true ->
          generic_lines(lines)
      end

    (["┌─ Diagram · #{kind_label(kind)}"] ++ rendered ++ ["└─"]) |> Enum.join("\n")
  end

  defp flow_lines(lines) do
    labels =
      lines
      |> Enum.flat_map(fn line ->
        case Regex.run(@flow_edge, line) do
          [_match, source, _connector, _edge_label, target] ->
            [node_definition(source), node_definition(target)]

          _none ->
            [node_definition(line)]
        end
      end)
      |> Enum.reduce(%{}, fn {id, label}, acc ->
        if id != label or not Map.has_key?(acc, id), do: Map.put(acc, id, label), else: acc
      end)

    edges =
      lines
      |> Enum.flat_map(&flow_edge(&1, labels))
      |> Enum.take(@edge_max_count)

    if edges == [], do: generic_lines(lines), else: edges
  end

  defp flow_edge(line, labels) do
    case Regex.run(@flow_edge, line) do
      [_match, source, connector, edge_label, target] ->
        source = display_node(source, labels)
        target = display_node(target, labels)
        edge = edge_display(connector, edge_label)
        [bounded("#{source} #{edge} #{target}")]

      _none ->
        []
    end
  end

  defp sequence_lines(lines) do
    rendered =
      lines
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^([^\s-]+)\s*(-->>|->>|-->|->)\s*([^:]+):\s*(.+)$/, line) do
          [_match, source, _arrow, target, message] ->
            [bounded("#{clean(source)} ── #{clean(message)} ──▶ #{clean(target)}")]

          _none ->
            []
        end
      end)
      |> Enum.take(@edge_max_count)

    if rendered == [], do: generic_lines(lines), else: rendered
  end

  defp generic_lines(lines) do
    lines
    |> Enum.take(@edge_max_count)
    |> Enum.map(&("  " <> bounded(&1)))
  end

  defp node_definition(line) do
    case Regex.run(~r/^([A-Za-z0-9_:.-]+)\s*[\[\(\{]+["']?([^\]\)\}]+?)["']?[\]\)\}]+$/, line) do
      [_match, id, label] -> {id, clean(label)}
      _none -> {line, clean(line)}
    end
  end

  defp display_node(token, labels) do
    token = String.trim(token)

    case node_definition(token) do
      {^token, label} -> Map.get(labels, token, label)
      {id, label} -> Map.get(labels, id, label)
    end
  end

  defp edge_display(connector, ""), do: if(connector in ["---", "-.->"], do: "──", else: "──▶")
  defp edge_display(_connector, label), do: "── #{clean(label)} ─▶"

  defp kind_label(kind) do
    kind |> String.split() |> List.first() |> String.replace("sequenceDiagram", "sequence")
  end

  defp blank_or_comment?(line), do: line == "" or String.starts_with?(line, "%%")
  defp clean(value), do: value |> String.trim() |> String.trim("\"") |> String.trim("'")
  defp bounded(value), do: TextBuffer.truncate_utf8(value, @line_max_bytes)
end
