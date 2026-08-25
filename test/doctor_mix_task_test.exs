defmodule ReyCode.DoctorMixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.ReyCode.Doctor

  @report %{
    app: %{name: "rey_code", version: "1.2.3"},
    system: %{os_family: "unix", os: "test-os", architecture: "test-arch"},
    runtime: %{elixir: "1.99.0", otp: "99"},
    paths: %{
      data: %{
        path: "/var/lib/rey_code",
        exists: true,
        type: :directory,
        readable: true,
        writable: true,
        free_bytes: 1_048_576
      },
      database: %{
        path: "/var/lib/rey_code/rey_code.sqlite3",
        exists: false,
        type: nil,
        readable: nil,
        writable: true,
        free_bytes: nil
      }
    },
    opencode: %{
      status: :configured,
      ready: true,
      installed: true,
      executable: "/usr/bin/opencode",
      version: "2.0.0"
    },
    omp: %{
      status: :missing,
      ready: false,
      installed: false,
      executable: nil,
      version: nil
    },
    api_providers: [
      %{
        id: :deepseek,
        name: "DeepSeek",
        endpoint: "https://api.deepseek.com"
      }
    ],
    limits: %{provider_timeout_ms: 600_000, squad_rework_budget: 3}
  }

  test "renders a concise human report" do
    output = Doctor.render(@report, :human)

    assert output =~ "ReyCode doctor"
    assert output =~ "Application: rey_code 1.2.3"
    assert output =~ "System: unix/test-os (test-arch)"
    assert output =~ "Runtime: Elixir 1.99.0, OTP 99"
    assert output =~ "Data path: /var/lib/rey_code"
    assert output =~ "free=1.0 MiB"
    assert output =~ "Database path: /var/lib/rey_code/rey_code.sqlite3"
    assert output =~ "readable=unknown"
    assert output =~ "OpenCode: status=configured, ready=yes"
    assert output =~ "DeepSeek (deepseek): endpoint=https://api.deepseek.com"
    assert output =~ "provider_timeout_ms=600000"
  end

  test "renders one machine-readable JSON document" do
    decoded = @report |> Doctor.render(:json) |> Jason.decode!()

    assert decoded["app"]["version"] == "1.2.3"
    assert decoded["paths"]["database"]["free_bytes"] == nil

    assert decoded["opencode"] == %{
             "executable" => "/usr/bin/opencode",
             "installed" => true,
             "ready" => true,
             "status" => "configured",
             "version" => "2.0.0"
           }
  end

  test "mix task emits JSON diagnostics" do
    Mix.Task.reenable("rey_code.doctor")

    output =
      capture_io(fn ->
        Mix.Task.run("rey_code.doctor", ["--json"])
      end)

    decoded = Jason.decode!(output)
    assert decoded["app"]["name"] == "rey_code"
    assert is_binary(decoded["app"]["version"])
    assert is_map(decoded["paths"]["database"])
    assert is_map(decoded["opencode"])
  end
end
