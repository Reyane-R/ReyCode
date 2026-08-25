defmodule ReyCode.Provider.OMP.Process do
  @moduledoc "Launches OMP RPC sessions with bounded process policy."

  alias ReyCode.Provider.OpenCode.Process, as: OpenCodeProcess
  alias ReyCode.RuntimeConfig.OMP, as: OMPPolicy

  @spec open_stream(binary(), [binary()], binary(), binary(), keyword()) :: Enumerable.t()
  def open_stream(executable, args, workspace, input, environment_opts) do
    OpenCodeProcess.open_stream(executable, args, workspace, input, environment_opts)
  end

  @spec collect(
          Enumerable.t(),
          (term(), term() -> {:cont, term()} | {:halt, term()}),
          term(),
          non_neg_integer(),
          keyword()
        ) :: {:ok, term()} | {:error, map()}
  def collect(stream, reducer, acc, timeout, opts),
    do: OpenCodeProcess.collect(stream, reducer, acc, timeout, opts)

  @doc "Builds the sandboxed environment options for OMP child processes."
  @spec environment_opts(OMPPolicy.t()) :: keyword()
  def environment_opts(%ReyCode.RuntimeConfig.OMP{} = policy) do
    [
      source: System.get_env(),
      additional_names: policy.env_allowlist,
      cpu_seconds: policy.cpu_seconds,
      open_files: policy.open_files
    ]
  end
end
