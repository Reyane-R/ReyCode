defmodule ReyCode.ApplicationBootTest do
  # The single deliberate global-boundary test: proves the production
  # application boots its named stack. Every other integration suite starts
  # its own isolated runtime.
  use ExUnit.Case, async: false

  test "boots the globally named EventStore, Catalog, and Engine stack" do
    assert is_pid(Process.whereis(ReyCode.EventStore))
    assert is_pid(Process.whereis(ReyCode.Provider.Catalog))
    assert is_pid(Process.whereis(ReyCode.Supervisor))
    assert %ReyCode.Orchestration.Projection{} = ReyCode.snapshot()
  end
end
