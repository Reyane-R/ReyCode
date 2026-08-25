defmodule Mix.Tasks.ReyCode.Doctor do
  @shortdoc "Reports production readiness diagnostics"

  @moduledoc """
  Reports runtime, storage path, CLI provider readiness, and configured limits.

      mix rey_code.doctor
      mix rey_code.doctor --json
  """

  use Mix.Task

  alias ReyCode.{Diagnostics, RuntimeConfig}

  @switches [json: :boolean]

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or args != [] do
      Mix.raise("Usage: mix rey_code.doctor [--json]")
    end

    config = RuntimeConfig.load!()
    path_config = Application.get_all_env(:rey_code)
    start_application_without_tui()

    report =
      Diagnostics.snapshot(
        app_version: Mix.Project.config()[:version],
        config: config,
        path_config: path_config
      )

    format = if opts[:json], do: :json, else: :human
    Mix.shell().info(render(report, format))
  end

  @doc false
  @spec render(Diagnostics.report(), :human | :json) :: String.t()
  def render(report, :json), do: Jason.encode!(report)

  def render(report, :human) do
    [
      "ReyCode doctor",
      "Application: #{report.app.name} #{report.app.version}",
      "System: #{report.system.os_family}/#{report.system.os} (#{report.system.architecture})",
      "Runtime: Elixir #{report.runtime.elixir}, OTP #{report.runtime.otp}",
      path_line("Data path", report.paths.data),
      path_line("Database path", report.paths.database),
      opencode_line(report.opencode),
      omp_line(report.omp),
      api_providers_lines(report.api_providers),
      "Limits:",
      limits_lines(report.limits)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp start_application_without_tui do
    previous = Application.get_env(:rey_code, :start_tui, :not_configured)
    Application.put_env(:rey_code, :start_tui, false)

    try do
      Mix.Task.run("app.start")
    after
      restore_tui_config(previous)
    end
  end

  defp restore_tui_config(:not_configured), do: Application.delete_env(:rey_code, :start_tui)
  defp restore_tui_config(value), do: Application.put_env(:rey_code, :start_tui, value)

  defp path_line(label, path) do
    "#{label}: #{path.path} " <>
      "(exists=#{answer(path.exists)}, readable=#{answer(path.readable)}, " <>
      "writable=#{answer(path.writable)}, free=#{format_bytes(path.free_bytes)})"
  end

  defp opencode_line(opencode) do
    "OpenCode: status=#{opencode.status}, ready=#{answer(opencode.ready)}, " <>
      "executable=#{opencode.executable || "not found"}, version=#{opencode.version || "unknown"}"
  end

  defp omp_line(omp) do
    "OMP: status=#{omp.status}, ready=#{answer(omp.ready)}, " <>
      "executable=#{omp.executable || "not found"}, version=#{omp.version || "unknown"}"
  end

  defp api_providers_lines([]), do: "API providers: none configured"

  defp api_providers_lines(providers) do
    lines = ["API providers:"]

    Enum.reduce(providers, lines, fn provider, acc ->
      acc ++
        [
          "  #{provider.name} (#{provider.id}): endpoint=#{provider.endpoint}"
        ]
    end)
  end

  defp limits_lines(limits) do
    limits
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "  #{key}=#{value}" end)
  end

  defp answer(true), do: "yes"
  defp answer(false), do: "no"
  defp answer(nil), do: "unknown"

  defp format_bytes(nil), do: "unknown"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: scaled_bytes(bytes, 1024, "KiB")
  defp format_bytes(bytes) when bytes < 1_073_741_824, do: scaled_bytes(bytes, 1_048_576, "MiB")
  defp format_bytes(bytes), do: scaled_bytes(bytes, 1_073_741_824, "GiB")

  defp scaled_bytes(bytes, divisor, unit) do
    value = (bytes / divisor) |> Float.round(1)
    "#{value} #{unit}"
  end
end
