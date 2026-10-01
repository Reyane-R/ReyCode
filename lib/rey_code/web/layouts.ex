defmodule ReyCode.Web.Layouts do
  @moduledoc false

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <meta name="color-scheme" content="dark" />
        <title>ReyCode</title>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@600&family=IBM+Plex+Mono:ital,wght@0,400;0,500;0,600;1,400&display=swap"
        />
        <style>
          <%= Phoenix.HTML.raw(css()) %>
        </style>
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/live_view/phoenix_live_view.min.js">
        </script>
        <script>
          <%= Phoenix.HTML.raw(js()) %>
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  defp js do
    """
    const csrf = document.querySelector("meta[name='csrf-token']").content;
    const hooks = {
      // Enter sends, Shift+Enter breaks the line; the server clears the box only after a send succeeds.
      Composer: {
        mounted() {
          const input = this.el.querySelector("textarea");
          const grow = () => { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, 320) + "px"; };
          input.addEventListener("input", grow);
          input.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); this.el.requestSubmit(); }
          });
          this.handleEvent("composer:clear", () => { input.value = ""; grow(); input.focus(); });
        }
      },
      // Follow new output only while the reader is already at the bottom.
      StickToBottom: {
        mounted() {
          this.atBottom = true;
          this.el.addEventListener("scroll", () => {
            this.atBottom = this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 120;
          });
          this.el.scrollTop = this.el.scrollHeight;
        },
        updated() { if (this.atBottom) this.el.scrollTop = this.el.scrollHeight; }
      }
    };
    new LiveView.LiveSocket("/live", Phoenix.Socket, {hooks, params: {_csrf_token: csrf}}).connect();
    """
  end

  # The TUI's palette (ReyCode.Theme): chrome recedes, cyan marks focus and
  # interaction only, rose is agent identity, yellow is "needs you", red is state.
  # ponytail: inline CSS, move to a stylesheet once a second page layout exists.
  defp css do
    """
    :root {
      --bg: #090508; --surface: #0E0709; --panel: #1C0D16; --line: #3B1119; --boundary: #5A1A24;
      --text: #E8E2E3; --muted: #9A8A91; --dim: #7D6E75;
      --cyan: #25E0FF; --rose: #D96B7C; --yellow: #FCEE09; --red: #FF5268; --green: #68E8AD;
      /* Monospace throughout, like the TUI; Chakra Petch only for the mark. */
      --mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
      --sans: var(--mono);
      --display: "Chakra Petch", var(--mono);
    }
    * { box-sizing: border-box; }
    html, body { height: 100%; }
    body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.65 var(--mono); }
    a { color: inherit; text-decoration: none; }
    :focus-visible { outline: 2px solid var(--cyan); outline-offset: 2px; border-radius: 4px; }
    .sr-only { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); }
    code, pre { font-family: var(--mono); font-size: 13px; }

    button { font: 500 14px/1 var(--sans); padding: 9px 14px; border-radius: 6px; cursor: pointer;
      border: 1px solid var(--line); background: var(--panel); color: var(--text); }
    button:hover { border-color: var(--boundary); }
    button.primary { background: var(--cyan); border-color: var(--cyan); color: var(--bg); }
    button.primary:hover { filter: brightness(1.1); }
    .icon-button { padding: 6px 10px; }

    /* Frame: sidebar | conversation | workers */
    .app { display: grid; grid-template-columns: 272px minmax(0, 1fr); height: 100vh; }
    .app.has-workers { grid-template-columns: 272px minmax(0, 1fr) 340px; }

    .sidebar { background: var(--surface); border-right: 1px solid var(--line); display: flex;
      flex-direction: column; min-height: 0; }
    .brand { display: flex; align-items: center; justify-content: space-between; padding: 18px 18px 10px; }
    .wordmark { font: 600 20px/1 var(--display); letter-spacing: 0.04em; color: var(--text); }
    .wordmark::after { content: ""; display: inline-block; width: 0.5em; height: 0.9em; margin-left: 4px;
      background: var(--cyan); vertical-align: -0.08em; }
    .menu-toggle { display: none; }
    .icon { flex: none; vertical-align: -3px; }
    .nav-row { display: flex; align-items: center; gap: 10px; margin: 0 8px; padding: 7px 10px; border-radius: 6px;
      font-size: 13.5px; color: var(--muted); }
    .nav-row:hover, .nav-row:focus-within { background: var(--panel); color: var(--text); }
    .new-chat { color: var(--text); }
    .new-chat .icon { color: var(--cyan); }
    .new-chat.inline { display: inline-flex; margin: 0; border: 1px solid var(--line); }
    .search input { flex: 1; min-width: 0; border: 0; background: transparent; color: var(--text); font: inherit;
      padding: 0; }
    .search input:focus { outline: none; }
    .search input::placeholder { color: var(--dim); }
    .search input::-webkit-search-cancel-button { filter: invert(0.6); }
    .show-more { display: block; margin: 2px 0 0; padding: 5px 10px; border: 0; background: none; color: var(--dim);
      font: 12.5px/1.4 var(--mono); }
    .show-more:hover { color: var(--cyan); }
    .sessions { overflow-y: auto; padding: 0 8px 24px; }
    .group h2 { display: flex; align-items: center; gap: 8px; font: 500 12px/1 var(--mono); color: var(--dim);
      margin: 18px 10px 6px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .session { display: flex; align-items: center; gap: 8px; padding: 6px 10px 6px 34px; border-radius: 6px;
      font-size: 13px; color: var(--muted); }
    .session:hover { background: var(--panel); color: var(--text); }
    .session.selected { background: var(--panel); color: var(--text); box-shadow: inset 2px 0 0 var(--cyan); }
    .session-title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .ago { font-size: 12px; color: var(--dim); font-variant-numeric: tabular-nums; }
    .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--rose); flex: none; }
    .empty-note { color: var(--dim); font-size: 14px; padding: 8px 10px; }

    /* Conversation */
    .conversation { display: flex; flex-direction: column; min-height: 0; min-width: 0; }
    .thread-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px;
      padding: 18px 32px 14px; border-bottom: 1px solid var(--line); }
    .thread-head h1 { font: 600 15px/1.4 var(--mono); margin: 0; }
    .workspace { margin: 2px 0 0; font: 12px/1.4 var(--mono); color: var(--dim); overflow: hidden;
      text-overflow: ellipsis; white-space: nowrap; }
    .working { font-size: 13px; color: var(--rose); white-space: nowrap; padding-top: 2px; }
    .working::before { content: ""; display: inline-block; width: 7px; height: 7px; border-radius: 50%;
      background: var(--rose); margin-right: 7px; animation: pulse 1.6s ease-in-out infinite; }

    .timeline { flex: 1; overflow-y: auto; padding: 24px 32px 8px; }
    .message { max-width: 760px; margin: 0 auto 26px; }
    .message.from-you { display: flex; justify-content: flex-end; }
    .author { font-size: 13px; font-weight: 600; color: var(--rose); margin-bottom: 4px; }
    .bubble { background: var(--panel); border: 1px solid var(--line); border-radius: 10px 10px 2px 10px;
      padding: 10px 14px; max-width: 85%; }
    .prose { overflow-wrap: anywhere; }
    .prose > :first-child { margin-top: 0; } .prose > :last-child { margin-bottom: 0; }
    .prose p, .prose ul, .prose ol, .prose pre, .prose table, .prose blockquote { margin: 0 0 12px; }
    .prose h1, .prose h2, .prose h3 { font-size: 15px; font-weight: 600; margin: 18px 0 8px; }
    .prose ul, .prose ol { padding-left: 22px; }
    .prose li { margin: 2px 0; }
    .prose a { color: var(--cyan); text-decoration: underline; text-underline-offset: 2px; }
    .prose code { background: var(--panel); border: 1px solid var(--line); border-radius: 4px; padding: 1px 5px; }
    .prose pre { background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 12px 14px;
      overflow-x: auto; line-height: 1.5; }
    .prose pre code { background: none; border: 0; padding: 0; }
    .prose blockquote { border-left: 2px solid var(--boundary); padding-left: 12px; color: var(--muted); }
    .prose table { border-collapse: collapse; display: block; overflow-x: auto; }
    .prose th, .prose td { border: 1px solid var(--line); padding: 5px 10px; text-align: left; }
    .streaming > :last-child::after { content: ""; display: inline-block; width: 0.55em; height: 1.05em;
      background: var(--cyan); margin-left: 3px; vertical-align: -0.15em; animation: blink 1s steps(1) infinite; }
    .streaming:empty::after { content: ""; display: inline-block; width: 0.55em; height: 1.05em;
      background: var(--cyan); animation: blink 1s steps(1) infinite; }
    .message.failed .author { color: var(--red); }
    .error { color: var(--red); font-size: 14px; margin: 6px 0 0; }
    .retry { max-width: 760px; margin: -12px auto 26px; }

    .tools { list-style: none; margin: 10px 0 0; padding: 0; border-left: 1px solid var(--line); }
    .tool { display: flex; gap: 10px; padding: 2px 0 2px 12px; font: 12.5px/1.5 var(--mono); color: var(--dim);
      min-width: 0; }
    .tool-label { color: var(--muted); flex: none; }
    .tool-target { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .tool.active .tool-label { color: var(--cyan); }
    .tool.failed .tool-label { color: var(--red); }
    .tool.more { font-style: italic; }

    /* Dock: what needs you, then the composer */
    .dock { padding: 8px 32px 18px; }
    .dock > * { max-width: 760px; margin-left: auto; margin-right: auto; }
    .needs-you { border: 1px solid var(--line); border-left: 3px solid var(--yellow); border-radius: 8px;
      background: var(--surface); padding: 12px 14px; margin-bottom: 10px; }
    .needs-you p { margin: 0; }
    .needs-you fieldset { border: 0; padding: 0; margin: 0 0 8px; }
    .needs-you legend { font-weight: 600; padding: 0; margin-bottom: 6px; }
    .args { margin: 8px 0 0; padding: 10px 12px; border-radius: 6px; background: var(--bg); max-height: 220px;
      overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; color: var(--muted); }
    .actions { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
    .option { display: flex; gap: 10px; align-items: flex-start; padding: 4px 0; cursor: pointer; }
    .option input { margin-top: 5px; accent-color: var(--cyan); }
    .hint { color: var(--dim); font-size: 12.5px; }
    .hint.block { display: block; }
    .other { margin-top: 6px; }
    .notice { color: var(--red); font-size: 14px; margin: 0 auto 8px; }

    .box { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 10px 12px 8px; }
    .box:focus-within { border-color: var(--boundary); }
    .box textarea { display: block; width: 100%; resize: none; border: 0; background: transparent; color: var(--text);
      font: 15px/1.55 var(--sans); padding: 2px 2px 6px; max-height: 320px; }
    .box textarea:focus { outline: none; }
    .box textarea::placeholder { color: var(--dim); }
    .box-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .box-row .grow { flex: 1; text-align: right; }
    .chip { display: inline-flex; align-items: center; gap: 6px; min-width: 0; max-width: 100%; padding: 4px 8px;
      border: 1px solid var(--line); border-radius: 6px; background: var(--panel); color: var(--muted); }
    .chip:focus-within { border-color: var(--cyan); }
    .chip select { min-width: 0; max-width: 260px; border: 0; color: var(--text); font: 12.5px/1.4 var(--mono);
      padding: 2px 18px 2px 0; text-overflow: ellipsis; appearance: none; cursor: pointer;
      background: transparent url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'%3E%3Cpath d='M1 1l4 4 4-4' fill='none' stroke='%239A8A91' stroke-width='1.4' stroke-linecap='round'/%3E%3C/svg%3E") no-repeat right 2px center / 9px 6px; }
    .chip select option { background: var(--panel); color: var(--text); }
    .chip select:focus { outline: none; }
    button.send { width: 34px; height: 34px; padding: 0; display: inline-grid; place-items: center; }
    button .icon { vertical-align: -3px; }
    input[type=text] { font: inherit; width: 100%; color: var(--text); background: var(--bg);
      border: 1px solid var(--line); border-radius: 6px; padding: 8px 10px; }

    /* Home */
    .home { margin: auto; width: min(680px, 100% - 32px); padding: 48px 0; }
    .mark { font: 600 56px/1 var(--display); letter-spacing: 0.03em; margin-bottom: 14px; }
    .mark::after { content: ""; display: inline-block; width: 0.46em; height: 0.82em; margin-left: 6px;
      background: var(--cyan); vertical-align: -0.06em; animation: blink 1.1s steps(1) 3; }
    .home h1 { font: 400 16px/1.4 var(--mono); color: var(--muted); margin: 0 0 26px; }
    .home .box textarea { min-height: 96px; }
    .home .box-row .send { margin-left: auto; }

    /* Workers rail */
    .workers { border-left: 1px solid var(--line); background: var(--surface); overflow-y: auto; padding: 18px 14px; }
    .workers h2 { font: 600 14px/1 var(--sans); margin: 0 0 14px 2px; }
    .count { color: var(--dim); font-weight: 400; margin-left: 4px; }
    .worker { border: 1px solid var(--line); border-radius: 8px; background: var(--bg); padding: 11px 12px;
      margin-bottom: 10px; }
    .worker header { display: flex; justify-content: space-between; gap: 8px; align-items: baseline; }
    .worker .state { font-size: 12.5px; color: var(--dim); }
    .worker.status-running .state, .worker.status-streaming .state { color: var(--cyan); }
    .worker.status-completed .state { color: var(--green); }
    .worker.status-failed .state, .worker.status-cancelled .state { color: var(--red); }
    .worker.status-waiting_tool_approval { border-left: 3px solid var(--yellow); }
    .worker.status-waiting_tool_approval .state { color: var(--yellow); }
    .meta { margin: 2px 0 0; font-size: 12.5px; color: var(--dim); }
    .worker details { margin-top: 8px; }
    .worker summary { cursor: pointer; font-size: 13px; color: var(--muted); }
    .report { white-space: pre-wrap; font-size: 13.5px; max-height: 260px; overflow: auto; margin-top: 6px;
      overflow-wrap: anywhere; }
    .changes p { margin: 10px 0 6px; font-size: 13px; }
    .diff { margin: 0; padding: 8px 10px; border-radius: 6px; background: var(--surface); max-height: 360px;
      overflow: auto; font-size: 12px; line-height: 1.45; }
    .diff span { display: block; min-height: 1.45em; white-space: pre; }
    .diff .add { color: var(--green); } .diff .del { color: var(--red); }
    .diff .hunk { color: var(--cyan); } .diff .meta { color: var(--dim); }

    @keyframes blink { 50% { opacity: 0; } }
    @keyframes pulse { 50% { opacity: 0.35; } }
    @media (prefers-reduced-motion: reduce) { * { animation: none !important; } }

    /* Narrow: workers stack above the dock, sidebar becomes a drawer */
    @media (max-width: 1180px) {
      .app.has-workers { grid-template-columns: 272px minmax(0, 1fr); grid-template-rows: minmax(0, 1fr) auto; }
      .app.has-workers .sidebar { grid-row: 1 / 3; }
      .app.has-workers .workers { grid-column: 2; border-left: 0; border-top: 1px solid var(--line);
        max-height: 34vh; display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 10px;
        align-content: start; }
      .app.has-workers .workers h2 { grid-column: 1 / -1; margin-bottom: 0; }
      .app.has-workers .worker { margin: 0; }
    }
    @media (max-width: 760px) {
      .app, .app.has-workers { grid-template-columns: minmax(0, 1fr); grid-template-rows: auto minmax(0, 1fr) auto; }
      .sidebar, .app.has-workers .sidebar { grid-row: 1; border-right: 0; border-bottom: 1px solid var(--line); }
      .app.has-workers .workers { grid-column: 1; grid-row: 3; }
      .brand { padding: 12px 16px; }
      .menu-toggle { display: inline-block; }
      .sidebar .nav-row, .sidebar .sessions { display: none; }
      .sidebar.open .nav-row { display: flex; }
      .sidebar.open .sessions { display: block; }
      .mark { font-size: 40px; }
      .sidebar.open .sessions { max-height: 50vh; }
      .thread-head, .timeline, .dock { padding-left: 16px; padding-right: 16px; }
      .bubble { max-width: 100%; }
    }
    """
  end
end
