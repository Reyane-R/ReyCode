defmodule ReyCode.Paths do
  @moduledoc """
  Platform-aware home directories for durable ReyCode files.

  One owner for the macOS/Linux split: data follows
  `~/Library/Application Support/ReyCode` on macOS and XDG data
  conventions elsewhere; logs follow `~/Library/Logs/ReyCode` on macOS
  and XDG state conventions elsewhere. Configuration overrides
  (`:data_dir`, `:log_dir`) remain first-choice at their call sites —
  this module only supplies the platform default.
  """

  @type os_type :: {:unix, :darwin} | {atom(), atom()}
  alias ReyCode.Security.CanonicalPath

  @doc "Canonicalizes an existing ancestor plus a bounded not-yet-created suffix."
  def canonical_future(path), do: canonical_future(Path.expand(path), 64)
  defp canonical_future(_path, 0), do: raise(ArgumentError, "path exceeds 64 ancestor levels")

  defp canonical_future(path, remaining) do
    case CanonicalPath.resolve(path) do
      {:ok, canonical} ->
        canonical

      {:error, :enoent} ->
        Path.join(canonical_future(Path.dirname(path), remaining - 1), Path.basename(path))

      {:error, reason} ->
        raise ArgumentError, "invalid configured path: #{inspect(reason)}"
    end
  end

  @doc "Platform default home for durable application data."
  @spec data_home(os_type(), String.t()) :: String.t()
  def data_home(os_type \\ :os.type(), xdg_data_home \\ xdg("XDG_DATA_HOME", "~/.local/share"))

  def data_home({:unix, :darwin}, _xdg_data_home),
    do: Path.expand("~/Library/Application Support/ReyCode")

  def data_home(_os_type, xdg_data_home), do: Path.join(xdg_data_home, "rey_code")

  @doc "Platform default home for log files."
  @spec log_home(os_type(), String.t()) :: String.t()
  def log_home(os_type \\ :os.type(), xdg_state_home \\ xdg("XDG_STATE_HOME", "~/.local/state"))

  def log_home({:unix, :darwin}, _xdg_state_home), do: Path.expand("~/Library/Logs/ReyCode")

  def log_home(_os_type, xdg_state_home), do: Path.join(xdg_state_home, "rey_code")

  defp xdg(env_var, fallback), do: System.get_env(env_var) || Path.expand(fallback)
end
