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

  defp mix_task?(path), do: String.starts_with?(path, "lib/mix/tasks/")
end
