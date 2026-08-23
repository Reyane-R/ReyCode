defmodule ReyCode.Orchestration.Engine.ProviderFrames do
  @moduledoc "Validates and deduplicates one contiguous provider-frame batch."

  alias ReyCode.Provider.Frame

  @spec collect(map(), [term()]) :: {:ok, [Frame.t()]} | {:error, atom()}
  def collect(invocation, frames) do
    frames
    |> Enum.reduce_while({:ok, [], invocation.last_frame_sequence}, &collect_frame/2)
    |> case do
      {:ok, pending, _cursor} -> {:ok, Enum.reverse(pending)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_frame(frame, {:ok, accepted, cursor}) do
    if Frame.validate(frame) != :ok do
      {:halt, {:error, :invalid_frame}}
    else
      cond do
        frame.sequence <= cursor -> {:cont, {:ok, accepted, cursor}}
        frame.sequence == cursor + 1 -> {:cont, {:ok, [frame | accepted], cursor + 1}}
        true -> {:halt, {:error, :invalid_frame_sequence}}
      end
    end
  end
end
