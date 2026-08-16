# capture_log: expected error/warning logs (stubbed failures, rejected uploads)
# stay out of the output and only print for failing tests.
ex_unit_options = [capture_log: true]

ex_unit_options =
  case System.get_env("REYCODE_TEST_TIMEOUT") do
    nil -> ex_unit_options
    timeout -> Keyword.put(ex_unit_options, :timeout, String.to_integer(timeout))
  end

case Application.ensure_all_started(:credo) do
  {:ok, _apps} -> :ok
  {:error, {:credo, {{:already_started, _pid}, _child}}} -> :ok
  {:error, {:credo, {:already_started, _pid}}} -> :ok
  {:error, reason} -> raise "failed to start Credo for tests: #{inspect(reason)}"
end

ExUnit.start(ex_unit_options)
