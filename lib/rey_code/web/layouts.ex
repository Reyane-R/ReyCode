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
        <title>ReyCode</title>
        <style>
          <%= Phoenix.HTML.raw(css()) %>
        </style>
        <script src="/assets/phoenix/phoenix.min.js">
        </script>
        <script src="/assets/live_view/phoenix_live_view.min.js">
        </script>
        <script>
          const csrf = document.querySelector("meta[name='csrf-token']").content;
          const hooks = {
            // Enter sends, Shift+Enter breaks the line; the server clears the box only after a send succeeds.
            Composer: {
              mounted() {
                const input = this.el.querySelector("textarea");
                input.addEventListener("keydown", (e) => {
                  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); this.el.requestSubmit(); }
                });
                this.handleEvent("composer:clear", () => { input.value = ""; input.focus(); });
              }
            },
            // Follow new output only while the reader is already at the bottom.
            StickToBottom: {
              mounted() { this.atBottom = true; window.addEventListener("scroll", () => {
                this.atBottom = window.innerHeight + window.scrollY >= document.body.scrollHeight - 160; });
                window.scrollTo(0, document.body.scrollHeight); },
              updated() { if (this.atBottom) window.scrollTo(0, document.body.scrollHeight); }
            }
          };
          new LiveView.LiveSocket("/live", Phoenix.Socket, {hooks, params: {_csrf_token: csrf}}).connect();
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  # ponytail: inline CSS, move to a stylesheet once there is more than one screen's worth.
  defp css do
    """
    :root { --bg:#fbfaf8; --fg:#1d1b18; --muted:#77716a; --line:#e7e3dd; --card:#fff; --accent:#c2410c;
      --ok-bg:#e7f5ec; --ok-fg:#15803d; --bad-bg:#fdecec; --bad-fg:#b91c1c; --run-bg:#e8effd; --run-fg:#1d4ed8; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#141210; --fg:#ece8e2; --muted:#9a938a; --line:#2a2622; --card:#1c1a17; --accent:#fb923c;
        --ok-bg:#12291b; --ok-fg:#4ade80; --bad-bg:#2c1414; --bad-fg:#f87171; --run-bg:#14203a; --run-fg:#60a5fa; }
    }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--fg);
      font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, sans-serif; }
    main { max-width: 860px; margin: 0 auto; padding: 32px 16px 80px; }
    a { color: inherit; text-decoration: none; }
    h1 { font-size: 20px; margin: 0 0 4px; }
    .muted { color: var(--muted); font-size: 13px; }
    .list a { display:block; padding:12px 14px; border:1px solid var(--line); border-radius:10px;
      background:var(--card); margin-bottom:8px; }
    .list a:hover { border-color: var(--accent); }
    .msg { padding: 14px 0; border-top: 1px solid var(--line); }
    .who { font-weight: 600; font-size: 13px; margin-bottom: 4px; }
    .who.agent { color: var(--accent); }
    .body { white-space: pre-wrap; overflow-wrap: anywhere; }
    .body pre, .body code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; }
    .status { font-weight: 400; color: var(--muted); margin-left: 6px; }
    h2 { font-size: 15px; margin: 28px 0 10px; }
    .workers { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 380px), 1fr)); gap: 12px; }
    .worker { border: 1px solid var(--line); border-radius: 10px; background: var(--card); padding: 12px 14px; min-width: 0; }
    .worker header { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
    .worker details { margin-top: 8px; }
    .worker summary { cursor: pointer; font-size: 13px; color: var(--muted); }
    .worker .body { max-height: 320px; overflow: auto; font-size: 14px; }
    .pill { font-size: 12px; padding: 1px 8px; border-radius: 999px; background: var(--line); color: var(--muted); white-space: nowrap; }
    .pill-running, .pill-streaming { background: var(--run-bg); color: var(--run-fg); }
    .pill-completed { background: var(--ok-bg); color: var(--ok-fg); }
    .pill-failed, .pill-cancelled { background: var(--bad-bg); color: var(--bad-fg); }
    .pill-waiting_tool_approval { background: var(--accent); color: var(--bg); }
    .diff { margin: 6px 0 0; padding: 8px; border-radius: 6px; background: var(--bg); overflow: auto; max-height: 420px;
      font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
    main.with-composer { padding-bottom: 170px; }
    button { font: inherit; font-size: 14px; padding: 6px 14px; border-radius: 8px; cursor: pointer;
      border: 1px solid var(--line); background: var(--card); color: var(--fg); }
    button:hover { border-color: var(--accent); }
    button.primary { background: var(--accent); border-color: var(--accent); color: var(--bg); }
    .buttons { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
    .action-card { border: 1px solid var(--accent); border-radius: 10px; background: var(--card); padding: 12px 14px; margin: 16px 0; }
    .action-card fieldset { border: 0; padding: 0; margin: 0 0 10px; }
    .action-card legend { padding: 0; margin-bottom: 6px; }
    .option { display: flex; gap: 8px; align-items: flex-start; padding: 4px 0; cursor: pointer; }
    .option input { margin-top: 4px; }
    .args { margin: 8px 0 0; padding: 8px; border-radius: 6px; background: var(--bg); overflow: auto; max-height: 240px;
      font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; white-space: pre-wrap; overflow-wrap: anywhere; }
    input[type=text], textarea { font: inherit; color: var(--fg); background: var(--bg); border: 1px solid var(--line);
      border-radius: 8px; padding: 8px 10px; width: 100%; }
    input[type=text]:focus, textarea:focus { outline: none; border-color: var(--accent); }
    .composer { position: fixed; left: 0; right: 0; bottom: 0; background: var(--bg); border-top: 1px solid var(--line);
      padding: 12px 16px 14px; }
    .composer > * { max-width: 860px; margin-left: auto; margin-right: auto; }
    .composer-row { display: flex; gap: 8px; align-items: flex-end; }
    .composer textarea { resize: vertical; min-height: 44px; max-height: 40vh; }
    .hint { margin-top: 4px; font-size: 12px; }
    .start .composer-row { margin-top: 8px; }
    select { font: inherit; font-size: 14px; color: var(--fg); background: var(--bg); border: 1px solid var(--line);
      border-radius: 8px; padding: 6px 8px; flex: 1; min-width: 0; }
    .list .pill { margin-left: 8px; }
    .notice { color: var(--bad-fg); font-size: 13px; margin-bottom: 6px; }
    .diff span { display: block; min-height: 1.45em; white-space: pre; }
    .diff .add { color: var(--ok-fg); } .diff .del { color: var(--bad-fg); }
    .diff .hunk { color: var(--run-fg); } .diff .meta { color: var(--muted); }
    """
  end
end
