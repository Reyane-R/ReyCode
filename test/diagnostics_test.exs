defmodule ReyCode.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias ReyCode.Diagnostics

  test "builds a deterministic sanitized report from injected probes" do
    database_path = Path.expand("tmp/diagnostics/rey_code.sqlite3")

    report =
      Diagnostics.snapshot(
        app_version: "9.8.7",
        config: %{
          event_path: database_path,
          provider_timeout_ms: 12_345,
          opencode_max_prompt_bytes: 4_096,
          squad_rework_budget: 5,
          secret_token: "must-not-leak"
        },
        system_info: %{os_family: "unix", os: "test-os", architecture: "test-arch"},
        runtime_info: %{elixir: "1.99.0", otp: "99"},
        path_probe: fn path ->
          %{
            exists: String.ends_with?(path, "diagnostics"),
            type: :directory,
            readable: true,
            writable: true
          }
        end,
        free_space_probe: fn path ->
          if String.ends_with?(path, "diagnostics"), do: {:ok, 8_192}, else: :unavailable
        end,
        catalog_snapshot: %{
          opencode: %{
            status: :configured,
            executable: "/opt/bin/opencode",
            version: "1.2.3",
            credential_count: 2,
            credential_names: ["private-account"],
            models: ["private/model"],
            error: "SECRET=value"
          }
        }
      )

    assert report.app == %{name: "rey_code", version: "9.8.7"}
    assert report.system == %{os_family: "unix", os: "test-os", architecture: "test-arch"}
    assert report.runtime == %{elixir: "1.99.0", otp: "99"}
    assert report.paths.data.path == Path.dirname(database_path)
    assert report.paths.data.free_bytes == 8_192
    assert report.paths.database.path == database_path
    assert report.paths.database.free_bytes == nil

    assert report.opencode == %{
             status: :configured,
             ready: true,
             installed: true,
             executable: "/opt/bin/opencode",
             version: "1.2.3"
           }

    assert report.limits.provider_timeout_ms == 12_345
    assert report.limits.opencode_max_prompt_bytes == 4_096
    assert report.limits.squad_rework_budget == 5
    assert report.limits.opencode_max_output_bytes == 10_000_000

    encoded = Jason.encode!(report)
    refute encoded =~ "must-not-leak"
    refute encoded =~ "private-account"
    refute encoded =~ "private/model"
    refute encoded =~ "SECRET=value"
    refute encoded =~ "DEEPSEEK_API_KEY"
    refute encoded =~ "has_key"
  end

  test "resolves the documented database path from an injected data home" do
    data_home = Path.expand("tmp/data-home")

    report =
      Diagnostics.snapshot(
        app_version: "1.0.0",
        config: [],
        data_home: data_home,
        system_info: %{os_family: "unix", os: "test", architecture: "arch"},
        runtime_info: %{elixir: "1.0", otp: "1"},
        path_probe: fn _path ->
          %{exists: false, type: nil, readable: nil, writable: false}
        end,
        free_space_probe: fn _path -> :unavailable end,
        catalog_snapshot: %{opencode: %{status: :missing}}
      )

    assert report.paths.data.path == data_home
    assert report.paths.database.path == Path.join(data_home, "rey_code.sqlite3")
    assert report.paths.database.exists == false
    assert report.paths.database.free_bytes == nil

    assert report.opencode == %{
             status: :missing,
             ready: false,
             installed: false,
             executable: nil,
             version: nil
           }
  end
end

defmodule ReyCode.DiagnosticsSanitizationTest do
  use ExUnit.Case, async: false

  alias ReyCode.Diagnostics

  test "provider endpoints expose only sanitized origins and never echo secrets" do
    previous_providers = Application.get_env(:rey_code, :openai_compatible_providers)
    System.put_env("REYCODE_SENTINEL_KEY", "sentinel-key-value")

    Application.put_env(:rey_code, :openai_compatible_providers, [
      %{
        id: :sentinel,
        name: "Sentinel",
        base_url:
          "https://sentinel-user:sentinel-pass@example.test:8443/secret-path?api_key=query-sentinel#frag-sentinel",
        key_env: "REYCODE_SENTINEL_KEY"
      },
      %{id: :broken, name: "Broken", base_url: "::::not a url::::", key_env: "REYCODE_MISSING"},
      %{id: :odd, name: "Odd", base_url: "ftp://files.example.test/pub", key_env: "REYCODE_MISSING"}
    ])

    on_exit(fn ->
      if previous_providers do
        Application.put_env(:rey_code, :openai_compatible_providers, previous_providers)
      else
        Application.delete_env(:rey_code, :openai_compatible_providers)
      end

      System.delete_env("REYCODE_SENTINEL_KEY")
    end)

    report =
      Diagnostics.snapshot(
        system_info: %{os_family: "unix", os: "test", architecture: "test"},
        runtime_info: %{elixir: "1.0", otp: "1"},
        catalog_snapshot: %{}
      )

    encoded = Jason.encode!(report)

    refute encoded =~ "sentinel-user"
    refute encoded =~ "sentinel-pass"
    refute encoded =~ "secret-path"
    refute encoded =~ "query-sentinel"
    refute encoded =~ "frag-sentinel"
    refute encoded =~ "sentinel-key-value"
    refute encoded =~ "::::not a url::::"
    refute encoded =~ "ftp://files.example.test"

    sentinel = Enum.find(report.api_providers, &(&1.id == :sentinel))
    assert sentinel.endpoint == "https://example.test:8443"

    assert Enum.find(report.api_providers, &(&1.id == :broken)).endpoint == "[unavailable]"
    assert Enum.find(report.api_providers, &(&1.id == :odd)).endpoint == "[unavailable]"
  end
end
