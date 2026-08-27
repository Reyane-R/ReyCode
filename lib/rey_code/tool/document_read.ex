defmodule ReyCode.Tool.DocumentRead do
  @moduledoc "Reads bounded HTTP documents as normalized UTF-8 text."

  @behaviour ReyCode.Tool

  alias ReyCode.Provider.Command
  alias ReyCode.RuntimeConfig.Tools.Research
  alias ReyCode.Tool.{Request, Result, Support}

  @impl true
  def run(%Request{arguments: arguments}, opts) do
    %Research{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, url} <- Support.require_arg(arguments, :url),
         {:ok, content, content_type} <- fetch(url, policy),
         {:ok, text} <- extract(content, content_type, policy.max_bytes) do
      Result.ok(text,
        metadata: %{"url" => url, "content_type" => content_type, "bytes" => byte_size(text)}
      )
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  @spec fetch(String.t(), Research.t()) :: {:ok, binary(), String.t()} | {:error, term()}
  def fetch(url, policy) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> do_fetch(url, policy)
      _ -> {:error, :invalid_document_url}
    end
  end

  defp do_fetch(url, policy) do
    options = [
      {:timeout, policy.document_timeout_ms},
      {:connect_timeout, policy.document_timeout_ms}
    ]

    case :httpc.request(:get, {String.to_charlist(url), []}, options, []) do
      {:ok, {{_version, status, _reason}, headers, body}} when status in 200..299 ->
        body = IO.iodata_to_binary(body)

        if byte_size(body) <= policy.max_bytes,
          do: {:ok, body, content_type(headers)},
          else: {:error, :document_too_large}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:document_status, status}}

      {:error, reason} ->
        {:error, {:document_request_failed, reason}}
    end
  end

  defp extract(body, content_type, max_bytes) do
    cond do
      String.contains?(String.downcase(content_type), "application/pdf") ->
        extract_pdf(body, max_bytes)

      String.contains?(String.downcase(content_type), "text/html") ->
        {:ok, html_text(body, max_bytes)}

      String.contains?(String.downcase(content_type), "json") ->
        pretty_json(body, max_bytes)

      String.valid?(body) ->
        {:ok, String.slice(body, 0, max_bytes)}

      true ->
        {:error, :document_binary_unsupported}
    end
  end

  defp pretty_json(body, max_bytes) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value |> Jason.encode!(pretty: true) |> String.slice(0, max_bytes)}
      {:error, _} -> {:ok, String.slice(body, 0, max_bytes)}
    end
  end

  defp html_text(body, max_bytes) do
    body
    |> String.replace(~r/<script\b[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style\b[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<br\s*\/?\s*>/i, "\n")
    |> String.replace(~r/<\/p\s*>/i, "\n\n")
    |> String.replace(~r/<[^>]+>/u, "")
    |> html_entities()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_bytes)
  end

  defp html_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp extract_pdf(body, max_bytes) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error, :pdf_text_extractor_not_found}

      executable ->
        path =
          Path.join(
            System.tmp_dir!(),
            "reycode-document-#{System.unique_integer([:positive])}.pdf"
          )

        try do
          with :ok <- File.write(path, body, [:binary]),
               {:ok, text} <-
                 Command.run(executable, [path, "-"],
                   timeout_ms: 10_000,
                   max_output_bytes: max_bytes
                 ) do
            {:ok, String.slice(text, 0, max_bytes)}
          else
            {:error, reason} -> {:error, {:pdf_extract_failed, reason}}
          end
        after
          File.rm(path)
        end
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value("application/octet-stream", fn {name, value} ->
      if String.downcase(to_string(name)) == "content-type", do: to_string(value), else: nil
    end)
    |> String.split(";", parts: 2)
    |> List.first()
  end
end
