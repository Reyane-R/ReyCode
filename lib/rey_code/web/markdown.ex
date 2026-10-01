defmodule ReyCode.Web.Markdown do
  @moduledoc """
  Renders model-written Markdown to sanitized HTML for ReyCode Desktop.

  Message bodies are untrusted: the sanitizer strips scripts, event handlers,
  and unknown tags, so rendered output is safe to insert raw.
  """

  alias ReyCode.Provider.TextBuffer

  @render_max_bytes 65_536

  @options [
    sanitize: MDEx.Document.default_sanitize_options(),
    syntax_highlight: nil,
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true]
  ]

  @spec to_html(String.t()) :: String.t()
  def to_html(""), do: ""

  def to_html(body) when is_binary(body) do
    body
    |> TextBuffer.truncate_utf8(@render_max_bytes)
    |> MDEx.to_html!(@options)
  rescue
    # A renderer failure must never hide the text; fall back to escaped plain text.
    _error -> body |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
