# Maintained dependencies

`breeze` is the MIT-licensed Breeze 0.5.0 Hex source. ReyCode carries a small
input interception extension so a view can capture an entire pointer gesture
before child controls consume it. Keep the extension covered by ReyCode's
integration tests; return to the published dependency when upstream exposes an
equivalent API.

Local changes:

- Optional `Breeze.View.intercept_input/2`: continue ordinary routing, replace
  a deferred input, or consume an event before any implicit/live child sees it.
- Read-only `element_layouts/1` and `scroll_offset_y/2` for hit testing.
- `Breeze.Markdown.render_lines/2`: styled lines with explicit soft-wrap copy
  separators; long code wrapping belongs to ReyCode's selection renderer.
- Markdown headings render as marker-free bold text without a background fill,
  so inline code cannot reset the heading style or create low-contrast spans.
- Pin BackBreeze to 0.4.2, matching ReyCode's pre-extension lockfile.

Integration coverage lives in `test/tui_test.exs`,
`test/tui_render_components_test.exs`, and `test/tui_text_selection_test.exs`.
Upstream: https://github.com/Gazler/breeze. Original license:
[`breeze/LICENCE.md`](breeze/LICENCE.md).
