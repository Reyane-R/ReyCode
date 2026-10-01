[
  plugins: [Breeze.HTMLFormatter],
  import_deps: [:breeze],
  subdirectories: ["lib/rey_code/web"],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,test,credo_checks,quality_tools}/**/*.{ex,exs}",
    "lib/*.ex",
    "lib/mix/**/*.{ex,exs}",
    "lib/rey_code/*.ex",
    # lib/rey_code/web has its own .formatter.exs (Phoenix HEEx, not Breeze)
    "lib/rey_code/{cli,event_store,local_engine,memory,orchestration,provider,runtime_config,security,tool,tui,verified_change}/**/*.{ex,exs}"
  ]
]
