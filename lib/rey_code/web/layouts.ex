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
          new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrf}}).connect();
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  # ponytail: inline CSS, move to a stylesheet once there is more than one screen's worth.
  defp css do
    """
    :root { --bg:#fbfaf8; --fg:#1d1b18; --muted:#77716a; --line:#e7e3dd; --card:#fff; --accent:#c2410c; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#141210; --fg:#ece8e2; --muted:#9a938a; --line:#2a2622; --card:#1c1a17; --accent:#fb923c; }
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
    """
  end
end
