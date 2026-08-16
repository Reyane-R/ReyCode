%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "credo_checks/", "quality_tools/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: [
        {Credo.Check.Readability.Specs, false},
        {ReyCode.CredoChecks.StringToAtom, []},
        {ReyCode.CredoChecks.ForbiddenHttpClients, []},
        {ReyCode.CredoChecks.RequireHttpTimeout, []},
        {ReyCode.CredoChecks.StructBracketAccess, []},
        {ReyCode.CredoChecks.ListBracketAccess, []}
      ]
    }
  ]
}
