defmodule ReyCode.ApplicationTest do
  use ExUnit.Case, async: false

  test "ensure_started_without_tui starts the app and restores the prior TUI setting" do
    previous = Application.get_env(:rey_code, :start_tui, :not_configured)

    assert {:ok, _applications} = ReyCode.Application.ensure_started_without_tui()

    case previous do
      :not_configured -> refute Application.get_env(:rey_code, :start_tui)
      value -> assert Application.get_env(:rey_code, :start_tui) == value
    end
  end

  test "interactive server enables mouse routing for transcript wheel scrolling" do
    spec = ReyCode.Application.tui_server_child_spec(ReyCode.RuntimeConfig.fresh())

    assert %{start: {Breeze.Server, :start_link, [options]}} = spec
    assert options[:mouse] == true
  end
end
