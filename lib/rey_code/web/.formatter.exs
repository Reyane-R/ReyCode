# Breeze's formatter owns ~H elsewhere in lib/; web templates are Phoenix HEEx.
[
  plugins: [Phoenix.LiveView.HTMLFormatter],
  import_deps: [:phoenix, :phoenix_live_view],
  inputs: ["*.ex"]
]
