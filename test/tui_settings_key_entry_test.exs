defmodule ReyCode.TUI.SettingsKeyEntryTest do
  use ExUnit.Case, async: false

  alias ReyCode.Failure
  alias ReyCode.Provider.Credentials
  alias ReyCode.TUI.{Notice, Settings}

  @catalog __MODULE__.Catalog
  @credentials __MODULE__.Creds
  @test_key_env "ZAI_API_KEY"

  defmodule StubCatalog do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, [], name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast(:refresh, state), do: {:noreply, state}
  end

  setup do
    System.delete_env(@test_key_env)
    # An injected credentials server keeps session keys and keychain writes
    # out of the shared application state.
    start_supervised!({Credentials, name: @credentials})
    start_supervised!({StubCatalog, @catalog})

    on_exit(fn -> System.delete_env(@test_key_env) end)

    :ok
  end

  test "confirming an unavailable keyed provider opens masked key entry" do
    result = Settings.confirm(providers_term())

    assert result.assigns.settings.step == :api_key
    assert result.assigns.settings.key_provider == :zai
    assert result.assigns.settings.api_key == ""
  end

  test "a rejected authentication also opens key entry for keyed providers" do
    settings = %{Settings.initial("room-1") | step: :providers, index: 2}
    providers = put_in(providers(), [:zai, :status], :error)

    providers =
      put_in(providers, [:zai, :failure], Failure.new(:authentication_failed, "no", false))

    result = Settings.confirm(term(settings: settings, providers: providers))

    assert result.assigns.settings.step == :api_key
  end

  test "key entry appends, backspaces, toggles persistence, and escapes back" do
    {:noreply, opened} = Settings.handle_input("K", providers_term())

    assert {:noreply, typed} = Settings.handle_input("a", opened)
    assert {:noreply, typed} = Settings.handle_input("b", typed)
    assert typed.assigns.settings.api_key == "ab"

    assert {:noreply, trimmed} = Settings.handle_input("Backspace", typed)
    assert trimmed.assigns.settings.api_key == "a"

    assert {:noreply, toggled} = Settings.handle_input("Tab", trimmed)
    refute toggled.assigns.settings.save_key?

    assert {:noreply, escaped} = Settings.handle_input("Escape", toggled)
    assert escaped.assigns.settings.step == :providers
    assert escaped.assigns.settings.api_key == ""
  end

  test "submit stores the session credential and waits for discovery" do
    {:noreply, opened} = Settings.handle_input("K", providers_term())
    {:noreply, typed} = Settings.handle_input("k", opened)
    {:noreply, typed} = Settings.handle_input("e", typed)
    {:noreply, typed} = Settings.handle_input("y", typed)
    # Persistence is off in tests: a real store would write the user keychain.
    {:noreply, typed} = Settings.handle_input("Tab", typed)

    assert {:noreply, submitted} = Settings.handle_input("Enter", typed)

    assert Credentials.fetch(@test_key_env, @credentials) == {:ok, "key", :session}
    assert %Notice{severity: :info} = submitted.assigns.notice
    assert submitted.assigns.settings.step == :api_key
  end

  test "reconciliation advances to model selection once discovery succeeds" do
    {:noreply, opened} = Settings.handle_input("K", providers_term())
    {:noreply, typed} = Settings.handle_input("k", opened)
    {:noreply, toggled} = Settings.handle_input("Tab", typed)
    {:noreply, submitted} = Settings.handle_input("Enter", toggled)

    connected = %{submitted.assigns.providers | zai: zai_entry(:configured, ["glm-4.6"])}
    submitted = %{submitted | assigns: %{submitted.assigns | providers: connected}}

    advanced = Settings.reconcile_options(submitted)

    assert advanced.assigns.settings.step == :models
    assert advanced.assigns.settings.provider == :zai
    assert %Notice{severity: :success} = advanced.assigns.notice
  end

  test "reconciliation reports a rejected key without clearing the entry" do
    {:noreply, opened} = Settings.handle_input("K", providers_term())
    {:noreply, typed} = Settings.handle_input("k", opened)
    {:noreply, toggled} = Settings.handle_input("Tab", typed)
    {:noreply, submitted} = Settings.handle_input("Enter", toggled)

    rejected = %{
      submitted.assigns.providers
      | zai: %{zai_entry(:error, []) | failure: Failure.new(:authentication_failed, "no", false)}
    }

    submitted = %{submitted | assigns: %{submitted.assigns | providers: rejected}}
    reconciled = Settings.reconcile_options(submitted)

    assert reconciled.assigns.settings.step == :api_key
    assert %Notice{severity: :warning, message: message} = reconciled.assigns.notice
    assert message =~ "rejected"
  end

  test "a configured provider still advances straight to model selection" do
    settings = %{Settings.initial("room-1") | step: :providers, index: 1}
    result = Settings.confirm(term(settings: settings))

    assert result.assigns.settings.step == :models
    assert result.assigns.settings.provider == :ollama
  end

  test "X reports keyless providers instead of removing anything" do
    settings = %{Settings.initial("room-1") | step: :providers, index: 1}
    {:noreply, removed} = Settings.handle_input("X", term(settings: settings))

    assert %Notice{severity: :info, message: message} = removed.assigns.notice
    assert message =~ "needs no API key"
  end

  # Registry order is deepseek, ollama, lmstudio, zai… so index 2 selects Z.ai.
  defp providers_term do
    settings = %{Settings.initial("room-1") | step: :providers, index: 2}
    term(settings: settings)
  end

  defp term(overrides) do
    session = %{
      participants: [
        %{id: "builder", name: "Builder", kind: :primary}
      ]
    }

    assigns = %{
      modal: :settings,
      notice: nil,
      mode: :direct,
      selected_session_id: "room-1",
      projection: %{sessions: %{"room-1" => session}},
      provider_catalog: @catalog,
      credentials: @credentials,
      providers: providers(),
      settings: Settings.initial("room-1")
    }

    %Breeze.Term{assigns: Map.merge(assigns, Map.new(overrides))}
  end

  defp providers do
    %{
      deepseek: %{id: :deepseek, name: "DeepSeek", status: :configured, models: ["deepseek-chat"]},
      ollama: %{id: :ollama, name: "Ollama", status: :configured, models: ["llama3"]},
      zai: zai_entry(:available, [])
    }
  end

  defp zai_entry(status, models) do
    %{id: :zai, name: "Z.ai", status: status, models: models, failure: nil}
  end
end
