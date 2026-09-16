defmodule ReyCode.TUI.SettingsModalRenderTest do
  use ExUnit.Case, async: false

  alias ReyCode.TUI.Settings

  defmodule CredentialServer do
    use GenServer
    def start_link(source), do: GenServer.start_link(__MODULE__, source)
    @impl true
    def init(source), do: {:ok, source}
    @impl true
    def handle_call({:fetch, "ZAI_API_KEY"}, _from, :offline),
      do: {:reply, {:error, :engine_disconnected}, :offline}

    def handle_call({:fetch, "ZAI_API_KEY"}, _from, source) do
      reply = if source, do: {:ok, "test-secret-not-for-display", source}, else: :error
      {:reply, reply, source}
    end
  end

  defmodule KeyView do
    use Breeze.View
    import ReyCode.TUI.Components.SettingsModal

    @impl true
    def mount(opts, term), do: {:ok, assign(term, opts)}

    @impl true
    def render(assigns), do: modal(Map.put(assigns, :term, assigns))
  end

  test "key entry renders flat assigns and uses the injected credential server without exposing secrets" do
    for source <- [nil, :session, :environment, :keychain, :offline] do
      server = start_supervised!({CredentialServer, source}, id: source)

      view =
        Breeze.Test.start!(KeyView,
          size: {100, 30},
          start_opts: [
            settings: %{
              Settings.initial()
              | step: :api_key,
                key_provider: :zai,
                api_key: "typed-secret-not-for-display",
                save_key?: false
            },
            credentials: server,
            notice: nil
          ]
        )

      on_exit(fn -> Breeze.Test.stop(view) end)
      screen = Breeze.Test.render!(view)
      assert screen =~ "Z.ai API key"
      assert screen =~ "this run only"

      label =
        case source do
          nil -> "no credential stored"
          :offline -> "credentials unavailable"
          _ -> "active key:"
        end

      assert screen =~ label
      refute screen =~ "typed-secret-not-for-display"
      refute screen =~ "test-secret-not-for-display"
    end
  end
end
