defmodule ReyCode.TUI.TimeAgo do
  @moduledoc "Formats durable timestamps as compact relative ages."

  @spec format(String.t() | nil) :: String.t()
  def format(nil), do: ""

  def format(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        from(DateTime.to_unix(datetime), DateTime.to_unix(DateTime.utc_now()))

      _other ->
        ""
    end
  end

  defp from(seconds, now) when seconds >= now, do: "just now"
  defp from(seconds, now) when now - seconds < 60, do: "just now"
  defp from(seconds, now) when now - seconds < 3_600, do: "#{div(now - seconds, 60)}m ago"
  defp from(seconds, now) when now - seconds < 86_400, do: "#{div(now - seconds, 3_600)}h ago"
  defp from(seconds, now) when now - seconds < 604_800, do: "#{div(now - seconds, 86_400)}d ago"

  defp from(seconds, _now), do: seconds |> DateTime.from_unix!() |> Calendar.strftime("%b %d")
end
