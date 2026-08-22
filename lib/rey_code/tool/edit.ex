defmodule ReyCode.Tool.Edit do
  @moduledoc "Replaces the first occurrence of a string within a file in the trusted roots."
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    path = Support.arg(arguments, :path)
    old = Support.arg(arguments, :old_string)
    new = Support.arg(arguments, :new_string, "")

    with :ok <- Support.require_present(path, :missing_path),
         :ok <- Support.require_present(old, :missing_old_string),
         {:ok, canonical} <- Support.within_roots(path, request) do
      replace_once(canonical, old, new)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp replace_once(canonical, old, new) do
    case File.read(canonical) do
      {:ok, content} ->
        replace_content(canonical, content, old, new)

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp replace_content(canonical, content, old, new) do
    if String.contains?(content, old) do
      updated = String.replace(content, old, new, global: false)
      write_updated(canonical, updated)
    else
      Result.error(:old_string_not_found)
    end
  end

  defp write_updated(canonical, updated) do
    case File.write(canonical, updated) do
      :ok -> Result.ok("edited #{canonical}")
      {:error, reason} -> Result.error(reason)
    end
  end
end
