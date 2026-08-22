defmodule ReyCode.Tool.Result do
  @moduledoc """
  The outcome of executing one tool against the workspace.

  Results are JSON-safe: `metadata` is a string-keyed map and `truncated`
  marks that captured output was cut off by a bound rather than completed.
  """

  @enforce_keys [:ok]
  defstruct [:ok, :output, :error, truncated: false, metadata: %{}]

  @type t :: %__MODULE__{
          ok: boolean(),
          output: String.t() | nil,
          error: term(),
          truncated: boolean(),
          metadata: map()
        }

  @spec ok(String.t(), keyword()) :: t()
  def ok(output, opts \\ []) when is_binary(output) do
    %__MODULE__{
      ok: true,
      output: output,
      truncated: Keyword.get(opts, :truncated, false),
      metadata: json_metadata(Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec error(term(), keyword()) :: t()
  def error(reason, opts \\ []) do
    %__MODULE__{
      ok: false,
      output: nil,
      error: reason,
      truncated: Keyword.get(opts, :truncated, false),
      metadata: json_metadata(Keyword.get(opts, :metadata, %{}))
    }
  end

  @doc "Encodes a result as the JSON-safe wire map stored on durable tool runs."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{ok: true} = result) do
    %{
      "ok" => true,
      "output" => result.output,
      "error" => nil,
      "truncated" => result.truncated,
      "metadata" => result.metadata
    }
  end

  def to_wire(%__MODULE__{ok: false} = result) do
    %{
      "ok" => false,
      "output" => nil,
      "error" => result.error,
      "truncated" => result.truncated,
      "metadata" => result.metadata
    }
  end

  defp json_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
  end

  defp json_metadata(_other), do: %{}
end
