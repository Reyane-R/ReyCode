defmodule ReyCode.Security.Environment do
  @moduledoc "Builds the minimal environment passed to provider processes."

  @fixed_names ~w(HOME USER LOGNAME TMPDIR LANG TERM PATH)
  @name ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @spec allowlisted(keyword()) :: %{optional(String.t()) => String.t()}
  def allowlisted(opts \\ []) do
    source = Keyword.get_lazy(opts, :source, &System.get_env/0)
    additional_names = opts |> Keyword.get(:additional_names, []) |> normalize_names()

    source
    |> Enum.filter(fn {name, _value} ->
      valid_name?(name) and
        (name in @fixed_names or String.starts_with?(name, "LC_") or name in additional_names)
    end)
    |> Map.new()
    |> Map.put("NO_COLOR", "1")
  end

  @doc false
  @spec launch_env(keyword()) :: %{optional(String.t()) => String.t()}
  def launch_env(opts \\ []) do
    source = Keyword.get_lazy(opts, :source, &System.get_env/0)
    allowed = allowlisted(Keyword.put(opts, :source, source))

    # Exile overlays Port environment values rather than replacing the environment.
    # Blank denied values so no inherited value reaches the provider process.
    source
    |> Map.new(fn {name, _value} -> {name, ""} end)
    |> Map.merge(allowed)
  end

  @doc false
  @spec wrap(binary(), [binary()], keyword()) :: {binary(), [binary()], map()}
  def wrap(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    allowed = allowlisted(opts)
    cpu_seconds = positive_limit(opts[:cpu_seconds], 900)
    open_files = positive_limit(opts[:open_files], 1_024)

    assignments =
      allowed
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map_join(" ", fn name -> ~s(#{name}="$#{name}") end)

    script = """
    ulimit -c 0
    ulimit -n #{open_files}
    ulimit -t #{cpu_seconds}
    trap 'trap "" TERM INT HUP; kill -TERM -- -$$ 2>/dev/null; sleep 0.1; kill -KILL -- -$$ 2>/dev/null' TERM INT HUP
    /usr/bin/env -i #{assignments} "$@" <&0 &
    child=$!
    wait "$child"
    status=$?
    trap - TERM INT HUP
    exit "$status"
    """

    {"/bin/sh", ["-c", script, "rey-code-provider", executable | args], launch_env(opts)}
  end

  defp normalize_names(name) when is_binary(name), do: normalize_names([name])

  defp normalize_names(names) when is_list(names) do
    names
    |> Enum.filter(&(is_binary(&1) and Regex.match?(@name, &1)))
    |> Enum.uniq()
  end

  defp normalize_names(_names), do: []

  defp valid_name?(name) when is_binary(name), do: Regex.match?(@name, name)
  defp valid_name?(_name), do: false

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default
end
