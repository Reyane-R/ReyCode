defmodule Quality.ProjectInvariantsTest do
  use ExUnit.Case, async: true

  alias ReyCode.QualityScanner

  # Known modules that legitimately call Process.sleep.
  @sleep_exemptions [
    "/provider/simulator.ex",
    "/provider/command.ex",
    "/provider/catalog.ex",
    "/diagnostics.ex",
    "/mix/tasks/"
  ]
  test "mix.exs must not depend on :httpoison, :tesla, or :finch" do
    deps = File.read!("mix.exs")

    refute String.contains?(deps, "{:httpoison"),
           "Found :httpoison dependency — use :httpc instead"

    refute String.contains?(deps, "{:tesla"),
           "Found :tesla dependency — use :httpc instead"

    refute String.contains?(deps, "{:finch"),
           "Found :finch dependency — use :httpc instead"
  end

  test "production code does not call String.to_atom/1" do
    matches =
      QualityScanner.scan(~r/String\.to_atom\(/,
        exclude: ["/test/", "/deps/", "/_build/"]
      )

    assert matches == [],
           "Found String.to_atom/1 in production code — use String.to_existing_atom/1:\n" <>
             QualityScanner.format_matches(matches)
  end

  test "production code does not call Process.sleep outside known exemptions" do
    matches =
      QualityScanner.scan(~r/Process\.sleep\(/,
        exclude: ["/test/", "/deps/", "/_build/"] ++ @sleep_exemptions
      )

    assert matches == [],
           "Found Process.sleep outside known exemptions (simulator, command, catalog):\n" <>
             QualityScanner.format_matches(matches)
  end

  test "every event type has a payload contract" do
    alias ReyCode.Event

    missing =
      Enum.reject(Event.types(), fn type ->
        match?(%{required: %{}}, Event.contract(type))
      end)

    assert missing == [],
           "Event types without payload contracts: #{inspect(missing)}"
  end
end
