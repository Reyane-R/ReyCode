defmodule ReyCode.Provider.Response do
  @moduledoc "The normalized result of exactly one provider round."

  alias ReyCode.Provider.ToolCall

  @enforce_keys [:text]
  defstruct [:text, :tool_calls, :usage]

  @type t :: %__MODULE__{
          text: String.t(),
          tool_calls: [ToolCall.t()],
          usage: map() | nil
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      text: Keyword.get(opts, :text, ""),
      tool_calls: Keyword.get(opts, :tool_calls, []),
      usage: Keyword.get(opts, :usage)
    }
  end

  @doc "Encodes the response as canonical, string-keyed wire data."
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = response) do
    %{
      "text" => response.text,
      "tool_calls" => Enum.map(response.tool_calls, &ToolCall.to_wire/1),
      "usage" => response.usage
    }
  end

  @doc "Rebuilds a response from canonical wire data, returning an error when malformed."
  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_response}
  def from_wire(data) when is_map(data) do
    with {:ok, text} <- text(data["text"]),
         {:ok, calls} <- calls(data["tool_calls"]) do
      {:ok, %__MODULE__{text: text, tool_calls: calls, usage: usage(data["usage"])}}
    end
  end

  def from_wire(_other), do: {:error, :invalid_response}

  defp text(text) when is_binary(text), do: {:ok, text}
  defp text(_other), do: {:error, :invalid_response}

  defp calls(calls) when is_list(calls) do
    calls
    |> Enum.reduce_while({:ok, []}, fn wire, {:ok, acc} ->
      case ToolCall.from_wire(wire) do
        {:ok, call} -> {:cont, {:ok, acc ++ [call]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp calls(_other), do: {:error, :invalid_response}

  defp usage(nil), do: nil
  defp usage(usage) when is_map(usage), do: usage
  defp usage(_other), do: nil
end
