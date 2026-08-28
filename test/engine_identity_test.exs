defmodule ReyCode.Orchestration.Engine.IdentityTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine.Identity

  describe "new_id/1" do
    test "returns a prefixed id with a separator" do
      assert String.starts_with?(Identity.new_id("room"), "room-")
      assert String.starts_with?(Identity.new_id("inv"), "inv-")
    end

    test "produces distinct ids for the same prefix" do
      ids = MapSet.new(1..100, fn _ -> Identity.new_id("turn") end)
      assert MapSet.size(ids) == 100
    end
  end

  describe "slugify/1" do
    test "downcases and replaces non-alphanumeric runs with hyphens" do
      assert Identity.slugify("Build My Feature!") == "build-my-feature"
    end

    test "collapses mixed separators and trims edges" do
      assert Identity.slugify("  Hello   World  ") == "hello-world"
    end

    test "falls back to session for a slugless title" do
      assert Identity.slugify("!!!") == "session"
    end
  end

  describe "unique_slug/2" do
    defp projection(sessions) do
      %{sessions: Map.new(sessions, fn {id, slug} -> {id, %{slug: slug}} end)}
    end

    test "keeps the base slug when unused" do
      assert Identity.unique_slug("alpha", projection(%{})) == "alpha"
    end

    test "appends a numeric suffix when the base slug is taken" do
      assert Identity.unique_slug("alpha", projection(%{"room-1" => "alpha"})) == "alpha-2"
    end

    test "skips to the first free suffix when several are taken" do
      sessions = %{"room-1" => "alpha", "room-2" => "alpha-2"}
      assert Identity.unique_slug("alpha", projection(sessions)) == "alpha-3"
    end
  end
end
