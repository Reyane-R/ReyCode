defmodule ReyCode.PathsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Paths

  @darwin {:unix, :darwin}
  @linux {:unix, :linux}

  describe "data_home" do
    test "macOS uses the Application Support convention" do
      assert Paths.data_home(@darwin, "/ignored/xdg") ==
               Path.expand("~/Library/Application Support/ReyCode")
    end

    test "Linux honors XDG_DATA_HOME" do
      assert Paths.data_home(@linux, "/custom/xdg/data") == "/custom/xdg/data/rey_code"
    end

    test "Linux falls back to ~/.local/share without XDG_DATA_HOME" do
      assert Paths.data_home(@linux, Path.expand("~/.local/share")) ==
               Path.expand("~/.local/share/rey_code")
    end
  end

  describe "log_home" do
    test "macOS uses the Library/Logs convention" do
      assert Paths.log_home(@darwin, "/ignored/xdg") == Path.expand("~/Library/Logs/ReyCode")
    end

    test "Linux honors XDG_STATE_HOME instead of a macOS-style path" do
      assert Paths.log_home(@linux, "/custom/xdg/state") == "/custom/xdg/state/rey_code"
    end

    test "Linux falls back to ~/.local/state" do
      assert Paths.log_home(@linux, Path.expand("~/.local/state")) ==
               Path.expand("~/.local/state/rey_code")
    end
  end
end
