defmodule ReyCode.RuntimeConfigBoundaryTest do
  use ExUnit.Case, async: true

  @bootstrap_files MapSet.new([
                     "lib/rey_code/application.ex",
                     "lib/rey_code/runtime_config.ex"
                   ])

  test "application configuration is read only at bootstrap boundaries" do
    violations =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(MapSet.member?(@bootstrap_files, &1) or mix_task?(&1)))
      |> Enum.filter(fn path ->
        Regex.match?(
          ~r/Application\.(?:get_env|get_all_env|fetch_env!?)/,
          File.read!(path)
        )
      end)

    assert violations == [],
           "runtime modules must use injected RuntimeConfig; violations: #{inspect(violations)}"
  end

  test "runtime tests do not mutate frozen application policy" do
    exempt =
      MapSet.new([
        "test/runtime_config_test.exs",
        "test/squad_mix_task_test.exs",
        "test/application_boot_test.exs"
      ])

    violations =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.reject(&MapSet.member?(exempt, &1))
      |> Enum.filter(fn path ->
        Regex.match?(
          ~r/Application\.(?:put_env|delete_env)\(\s*:rey_code/s,
          File.read!(path)
        )
      end)

    assert violations == [],
           "tests must inject RuntimeConfig instead of mutating frozen policy: #{inspect(violations)}"
  end

  defp mix_task?(path), do: String.starts_with?(path, "lib/mix/tasks/")
end
