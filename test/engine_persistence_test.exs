defmodule ReyCode.Orchestration.Engine.PersistenceTest do
  use ExUnit.Case, async: true

  alias ReyCode.Orchestration.Engine.Persistence
  alias ReyCode.Orchestration.Engine.Persistence.{DurableAppendError, DurableLoadError}
  alias ReyCode.Orchestration.Projector

  defmodule FailingStore do
    use GenServer

    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)
    def init(reason), do: {:ok, reason}

    def handle_call({:append_many, _entries, _opts}, _from, reason) do
      {:reply, {:error, reason}, reason}
    end

    def handle_call(:load_projection, _from, reason), do: {:reply, {:error, reason}, reason}
  end

  test "raises an explicit fail-stop error when a durable append fails" do
    store = start_supervised!({FailingStore, :disk_full})

    state = %{
      projection: Projector.initial(),
      event_store: store,
      event_registry: __MODULE__.UnusedRegistry
    }

    error =
      assert_raise DurableAppendError, fn ->
        Persistence.append_and_apply!(state, [
          {:event_that_will_not_persist, %{}, aggregate_type: :system}
        ])
      end

    assert error.reason == :disk_full
    assert error.entry_count == 1
    assert Exception.message(error) =~ "durable orchestration append failed"
  end

  test "raises an explicit fail-stop error when durable restore fails" do
    store = start_supervised!({FailingStore, :corrupt_store})

    error = assert_raise DurableLoadError, fn -> Persistence.restore!(store) end

    assert error.reason == :corrupt_store
    assert Exception.message(error) =~ "durable orchestration restore failed"
  end
end
