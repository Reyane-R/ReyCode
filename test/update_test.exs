defmodule ReyCode.UpdateTest do
  use ExUnit.Case, async: true
  alias ReyCode.RuntimeConfig
  alias ReyCode.TUI.State
  alias ReyCode.Update

  @payload ~s({"tag_name": "v9.9.9", "html_url": "https://github.com/Reyane-R/ReyCode/releases/tag/v9.9.9"})

  test "parses a release payload against the running version" do
    {:ok, info} = Update.from_payload(Jason.decode!(@payload))
    assert info.latest == "v9.9.9"
    assert info.update?
    assert info.url =~ "/releases/tag/v9.9.9"
    assert info.current == Update.current()
  end

  test "an equal or older release is not an update" do
    current = Update.current()
    {:ok, info} = Update.from_payload(%{"tag_name" => "v#{current}"})
    refute info.update?

    {:ok, older} = Update.from_payload(%{"tag_name" => "v0.0.1"})
    refute older.update?
  end

  test "malformed payloads fail closed" do
    assert Update.from_payload(%{}) == {:error, :invalid_update_payload}
    assert Update.from_payload(%{"tag_name" => ""}) == {:error, :invalid_update_payload}
    assert Update.from_payload("not json") == {:error, :invalid_update_payload}
  end

  test "notices point at the reycode update command and stay bounded" do
    {:ok, info} = Update.from_payload(Jason.decode!(@payload))
    notice = Update.notice(info)
    assert notice =~ "Update available:"
    assert notice =~ "run `reycode update`"
    assert byte_size(notice) <= 96
    assert Update.notice(%{update?: false}) == nil
  end

  test "the configuration flag controls update checks" do
    assert Update.check_enabled?(RuntimeConfig.fresh().tui)
    refute Update.check_enabled?(RuntimeConfig.fresh(tui_update_check: false).tui)

    assert {:error, :update_check_disabled} =
             Update.check(RuntimeConfig.fresh(tui_update_check: false))
  end

  test "auto checks never run from a source checkout" do
    refute Update.auto_check?(RuntimeConfig.fresh().tui)
  end

  test "the forced gate spawns a silent bounded check" do
    config = RuntimeConfig.fresh(tui_update_check: false)

    assert :ok =
             State.maybe_check_updates(self(), config, fn _tui -> true end)

    refute_received {:update_available, _}
  end

  test "deliver announces updates and stays silent otherwise" do
    {:ok, info} = Update.from_payload(Jason.decode!(@payload))

    assert Update.deliver(self(), {:ok, info}) == :ok
    assert_receive {:update_available, "Update available: " <> _}

    assert Update.deliver(self(), {:error, :update_check_disabled}) == :ok
    refute_received {:update_available, _}
  end

  test "notify_when_newer stays silent when checks are disabled" do
    config = RuntimeConfig.fresh(tui_update_check: false)
    assert Update.notify_when_newer(self(), config) == :ok
    refute_received {:update_available, _}
  end
end
