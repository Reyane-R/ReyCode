defmodule ReyCode.Tool.Edit do
  @moduledoc """
  Replaces exactly one occurrence of a string within a file in the trusted
  roots.

  The match must be unique: zero occurrences fails with
  `:old_string_not_found` and more than one fails with `:ambiguous_match`,
  so a stale or under-specified anchor can never silently rewrite the wrong
  part of a file.
  """
  @behaviour ReyCode.Tool

  alias ReyCode.Tool.{Request, Result, Support}

  @max_bytes_default 512_000

  defp max_bytes, do: Application.get_env(:rey_code, :tool_edit_max_bytes, @max_bytes_default)

  @impl true
  def run(%Request{arguments: arguments} = request, _opts) do
    path = Support.arg(arguments, :path)
    old = Support.arg(arguments, :old_string)
    new = Support.arg(arguments, :new_string, "")

    with :ok <- Support.require_present(path, :missing_path),
         :ok <- Support.require_present(old, :missing_old_string),
         :ok <- require_size(old, new),
         {:ok, canonical} <- Support.within_roots(path, request) do
      replace_once(canonical, old, new)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp require_size(old, new) do
    if byte_size(old) + byte_size(new) > max_bytes(),
      do: {:error, :content_too_large},
      else: :ok
  end

  defp replace_once(canonical, old, new) do
    case File.read(canonical) do
      {:ok, content} ->
        content
        |> occurrences(old)
        |> apply_replacement(content, canonical, old, new)

      {:error, reason} ->
        Result.error(reason)
    end
  end

  defp occurrences(content, old), do: length(:binary.matches(content, old))

  defp apply_replacement(0, _content, _canonical, _old, _new),
    do: Result.error(:old_string_not_found)

  defp apply_replacement(count, _content, _canonical, _old, _new) when count > 1,
    do: Result.error(:ambiguous_match)

  defp apply_replacement(1, content, canonical, old, new) do
    updated = :binary.replace(content, old, new)

    case File.write(canonical, updated) do
      :ok ->
        Result.ok("edited #{canonical}",
          metadata: %{"path" => canonical, "occurrences" => 1}
        )

      {:error, reason} ->
        Result.error(reason)
    end
  end
end
