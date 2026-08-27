defmodule ReyCode.Tool.LSP do
  @moduledoc """
  Runs one bounded Language Server Protocol operation against a configured stdio server.

  Each call initializes a fresh server for the Invocation workspace, opens one
  bounded UTF-8 document, performs one request, and shuts the process down.
  Read-only operations return bounded JSON. `rename` applies only a validated
  `WorkspaceEdit.changes` set after the durable ToolRun has owner approval.
  """

  @behaviour ReyCode.Tool

  alias ReyCode.Hashing
  alias ReyCode.RuntimeConfig.Tools.LSP, as: LSPPolicy
  alias ReyCode.Security.{Environment, Workspace}
  alias ReyCode.Tool.{Request, Result, Support}

  @read_actions ~w(diagnostics definition references hover symbols implementation code_actions)
  @write_actions ~w(rename)
  @actions @read_actions ++ @write_actions
  @language_ids %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".go" => "go",
    ".js" => "javascript",
    ".jsx" => "javascriptreact",
    ".py" => "python",
    ".rs" => "rust",
    ".ts" => "typescript",
    ".tsx" => "typescriptreact"
  }

  @impl true
  def run(%Request{arguments: arguments} = request, opts) do
    %LSPPolicy{} = policy = Keyword.fetch!(opts, :policy)

    with {:ok, action} <- Support.require_arg(arguments, :action),
         :ok <- known_action(action),
         {:ok, canonical} <- Support.require_path(arguments, :file, request),
         {:ok, content} <- bounded_file(canonical, policy.max_file_bytes),
         {:ok, position} <- position(arguments),
         {:ok, command} <- configured_command(policy.command),
         {:ok, response} <-
           request(
             command,
             request.workspace,
             canonical,
             content,
             action,
             position,
             arguments,
             policy
           ) do
      handle_response(action, response, request, policy)
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  @doc "Returns true when one action can mutate workspace files."
  @spec mutating_action?(term()) :: boolean()
  def mutating_action?(action), do: action in @write_actions

  defp known_action(action) do
    if action in @actions, do: :ok, else: {:error, :unsupported_lsp_action}
  end

  defp configured_command([executable | args])
       when is_binary(executable) and executable != "" and is_list(args),
       do: {:ok, {executable, args}}

  defp configured_command(_command), do: {:error, :lsp_not_configured}

  defp bounded_file(path, max_file_bytes) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= max_file_bytes,
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) and not String.contains?(content, <<0>>) do
      {:ok, content}
    else
      false -> {:error, :lsp_file_too_large_or_binary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp position(arguments) do
    with {:ok, line} <- Support.integer_arg(arguments, :line, 1),
         {:ok, character} <- Support.integer_arg(arguments, :character, 0),
         true <- line >= 1 do
      {:ok, %{"line" => line - 1, "character" => character}}
    else
      _error -> {:error, :invalid_lsp_position}
    end
  end

  defp request({executable, args}, workspace, file, content, action, position, arguments, policy) do
    environment_opts = [
      source: System.get_env(),
      additional_names: policy.env_allowlist,
      cpu_seconds: policy.cpu_seconds,
      open_files: policy.open_files
    ]

    {wrapper, wrapped_args, env} = Environment.wrap(executable, args, environment_opts)

    case open_port(wrapper, wrapped_args, workspace, env) do
      {:ok, port} ->
        try do
          run_protocol(port, workspace, file, content, action, position, arguments, policy)
        after
          close_port(port)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_port(executable, args, workspace, env) do
    options = [
      :binary,
      :exit_status,
      :use_stdio,
      {:args, Enum.map(args, &String.to_charlist/1)},
      {:cd, String.to_charlist(workspace)},
      {:env,
       Enum.map(env, fn {name, value} ->
         {String.to_charlist(name), String.to_charlist(value)}
       end)}
    ]

    {:ok, Port.open({:spawn_executable, String.to_charlist(executable)}, options)}
  rescue
    error in ErlangError -> {:error, {:lsp_launch_failed, Exception.message(error)}}
  end

  defp run_protocol(port, workspace, file, content, action, position, arguments, policy) do
    deadline_ms = monotonic_ms() + policy.timeout_ms
    root_uri = file_uri(workspace)
    file_uri = file_uri(file)

    initialize = %{
      "processId" => nil,
      "rootUri" => root_uri,
      "capabilities" => %{
        "textDocument" => %{
          "definition" => %{},
          "references" => %{},
          "hover" => %{},
          "documentSymbol" => %{},
          "implementation" => %{},
          "diagnostic" => %{},
          "rename" => %{"prepareSupport" => false},
          "codeAction" => %{}
        },
        "workspace" => %{"workspaceEdit" => %{"documentChanges" => false}}
      }
    }

    with :ok <- send_request(port, 1, "initialize", initialize),
         {:ok, _initialize, buffer} <-
           await_response(port, 1, deadline_ms, "", policy.max_output_bytes),
         :ok <- send_notification(port, "initialized", %{}),
         :ok <-
           send_notification(port, "textDocument/didOpen", %{
             "textDocument" => %{
               "uri" => file_uri,
               "languageId" => language_id(file),
               "version" => 1,
               "text" => content
             }
           }),
         {:ok, method, params} <- operation(action, file_uri, position, arguments),
         :ok <- send_request(port, 2, method, params),
         {:ok, response, _buffer} <-
           await_response(port, 2, deadline_ms, buffer, policy.max_output_bytes) do
      {:ok, response}
    end
  end

  defp operation("diagnostics", uri, _position, _arguments),
    do: {:ok, "textDocument/diagnostic", %{"textDocument" => %{"uri" => uri}}}

  defp operation("definition", uri, position, _arguments),
    do: text_position("textDocument/definition", uri, position)

  defp operation("references", uri, position, _arguments) do
    {:ok, "textDocument/references",
     %{
       "textDocument" => %{"uri" => uri},
       "position" => position,
       "context" => %{"includeDeclaration" => true}
     }}
  end

  defp operation("hover", uri, position, _arguments),
    do: text_position("textDocument/hover", uri, position)

  defp operation("symbols", uri, _position, _arguments),
    do: {:ok, "textDocument/documentSymbol", %{"textDocument" => %{"uri" => uri}}}

  defp operation("implementation", uri, position, _arguments),
    do: text_position("textDocument/implementation", uri, position)

  defp operation("code_actions", uri, position, _arguments) do
    {:ok, "textDocument/codeAction",
     %{
       "textDocument" => %{"uri" => uri},
       "range" => %{"start" => position, "end" => position},
       "context" => %{"diagnostics" => []}
     }}
  end

  defp operation("rename", uri, position, arguments) do
    case Support.require_arg(arguments, :new_name) do
      {:ok, new_name} when new_name != "" ->
        {:ok, "textDocument/rename",
         %{"textDocument" => %{"uri" => uri}, "position" => position, "newName" => new_name}}

      _error ->
        {:error, :lsp_new_name_required}
    end
  end

  defp text_position(method, uri, position),
    do: {:ok, method, %{"textDocument" => %{"uri" => uri}, "position" => position}}

  defp send_request(port, id, method, params),
    do:
      send_record(port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

  defp send_notification(port, method, params),
    do: send_record(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})

  defp send_record(port, record) do
    body = Jason.encode!(record)
    frame = ["Content-Length: ", Integer.to_string(byte_size(body)), "\r\n\r\n", body]

    Port.command(port, frame)
    :ok
  end

  defp await_response(port, id, deadline_ms, buffer, max_output_bytes) do
    case decode_frames(buffer) do
      {:ok, records, rest} ->
        case Enum.find(records, &(Map.get(&1, "id") == id)) do
          %{"error" => error} -> {:error, {:lsp_error, bounded_json(error, max_output_bytes)}}
          %{"result" => result} -> {:ok, result, rest}
          nil -> receive_response(port, id, deadline_ms, rest, max_output_bytes)
        end

      :incomplete ->
        receive_response(port, id, deadline_ms, buffer, max_output_bytes)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(port, id, deadline_ms, buffer, max_output_bytes) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      {:error, :lsp_timeout}
    else
      receive do
        {^port, {:data, data}} ->
          next = buffer <> data

          if byte_size(next) > max_output_bytes,
            do: {:error, :lsp_output_too_large},
            else: await_response(port, id, deadline_ms, next, max_output_bytes)

        {^port, {:exit_status, status}} ->
          {:error, {:lsp_exit, status}}
      after
        remaining_ms -> {:error, :lsp_timeout}
      end
    end
  end

  defp decode_frames(buffer), do: decode_frames(buffer, [])

  defp decode_frames(buffer, records) do
    case decode_frame(buffer) do
      :incomplete ->
        if records == [], do: :incomplete, else: {:ok, Enum.reverse(records), buffer}

      {:ok, record, rest} ->
        decode_frames(rest, [record | records])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_frame(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch -> :incomplete
      {header_end, 4} -> decode_frame(buffer, header_end)
    end
  end

  defp decode_frame(buffer, header_end) do
    header = binary_part(buffer, 0, header_end)
    body_start = header_end + 4

    with {:ok, content_length} <- content_length(header),
         true <- byte_size(buffer) >= body_start + content_length do
      decode_frame_body(buffer, body_start, content_length)
    else
      false -> :incomplete
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_frame_body(buffer, body_start, content_length) do
    body = binary_part(buffer, body_start, content_length)
    rest_start = body_start + content_length
    rest = binary_part(buffer, rest_start, byte_size(buffer) - rest_start)

    case Jason.decode(body) do
      {:ok, record} -> {:ok, record, rest}
      {:error, _reason} -> {:error, :invalid_lsp_json}
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(&content_length_value/1)
    |> case do
      {length, ""} when length >= 0 -> {:ok, length}
      _other -> {:error, :invalid_lsp_frame}
    end
  end

  defp content_length_value(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> content_length_value(String.downcase(String.trim(name)), value)
      _other -> nil
    end
  end

  defp content_length_value("content-length", value), do: Integer.parse(String.trim(value))
  defp content_length_value(_name, _value), do: nil

  defp handle_response("rename", response, request, policy),
    do: apply_workspace_edit(response, request, policy)

  defp handle_response(_action, response, _request, policy) do
    output = Jason.encode!(response)

    if byte_size(output) <= policy.max_output_bytes,
      do: Result.ok(output),
      else: Result.error(:lsp_output_too_large)
  end

  defp apply_workspace_edit(%{"changes" => changes}, request, policy) when is_map(changes) do
    with {:ok, files} <- prepare_files(changes, request, policy),
         :ok <- apply_files(files) do
      Result.ok("applied LSP workspace edit",
        metadata: %{
          "files" => length(files),
          "edits" => Enum.reduce(files, 0, &(&2 + length(&1.edits))),
          "paths" => Enum.map(files, & &1.path)
        }
      )
    else
      {:error, reason} -> Result.error(reason)
    end
  end

  defp apply_workspace_edit(nil, _request, _policy), do: Result.error(:lsp_rename_unavailable)

  defp apply_workspace_edit(_response, _request, _policy),
    do: Result.error(:unsupported_workspace_edit)

  defp prepare_files(changes, request, policy) do
    Enum.reduce_while(changes, {:ok, [], 0}, fn {uri, edits}, {:ok, files, edit_count} ->
      next_count = edit_count + if(is_list(edits), do: length(edits), else: policy.max_edits + 1)

      with true <- next_count <= policy.max_edits,
           {:ok, path} <- file_path(uri),
           {:ok, canonical} <- Workspace.contained?(path, roots: request.roots),
           {:ok, content} <- bounded_file(canonical, policy.max_file_bytes),
           {:ok, updated} <- apply_text_edits(content, edits) do
        file = %{
          path: canonical,
          source: content,
          source_hash: Hashing.sha256_hex(content),
          updated: updated,
          edits: edits
        }

        {:cont, {:ok, [file | files], next_count}}
      else
        false -> {:halt, {:error, :too_many_lsp_edits}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files, _count} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp apply_text_edits(content, edits) when is_list(edits) do
    with {:ok, replacements} <- text_replacements(content, edits),
         :ok <- non_overlapping(replacements) do
      {:ok, replace_text(content, replacements)}
    end
  end

  defp apply_text_edits(_content, _edits), do: {:error, :invalid_lsp_edits}

  defp text_replacements(content, edits) do
    Enum.reduce_while(edits, {:ok, []}, fn edit, {:ok, replacements} ->
      with %{
             "range" => %{"start" => start_position, "end" => end_position},
             "newText" => new_text
           } <- edit,
           true <- is_binary(new_text),
           {:ok, start_byte} <- byte_offset(content, start_position),
           {:ok, end_byte} <- byte_offset(content, end_position),
           true <- start_byte <= end_byte do
        replacement = %{position: start_byte, length: end_byte - start_byte, new: new_text}
        {:cont, {:ok, [replacement | replacements]}}
      else
        _error -> {:halt, {:error, :invalid_lsp_edit}}
      end
    end)
  end

  defp byte_offset(content, %{"line" => line, "character" => character})
       when is_integer(line) and line >= 0 and is_integer(character) and character >= 0 do
    lines = String.split(content, "\n", trim: false)

    case Enum.fetch(lines, line) do
      {:ok, text} ->
        prefix_bytes = lines |> Enum.take(line) |> Enum.reduce(0, &(&2 + byte_size(&1) + 1))

        with {:ok, line_bytes} <- utf16_byte_offset(text, character) do
          {:ok, prefix_bytes + line_bytes}
        end

      :error ->
        {:error, :invalid_lsp_position}
    end
  end

  defp byte_offset(_content, _position), do: {:error, :invalid_lsp_position}

  defp utf16_byte_offset(text, target_units) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while({0, 0}, fn codepoint, {units, bytes} ->
      cond do
        units == target_units ->
          {:halt, {:ok, bytes}}

        units > target_units ->
          {:halt, {:error, :invalid_utf16_position}}

        true ->
          {:cont,
           {units + if(codepoint > 0xFFFF, do: 2, else: 1),
            bytes + byte_size(<<codepoint::utf8>>)}}
      end
    end)
    |> case do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} = error -> error
      {^target_units, bytes} -> {:ok, bytes}
      _other -> {:error, :invalid_utf16_position}
    end
  end

  defp non_overlapping(replacements) do
    replacements
    |> Enum.sort_by(& &1.position)
    |> Enum.reduce_while(0, fn replacement, previous_end ->
      if replacement.position < previous_end,
        do: {:halt, {:error, :overlapping_lsp_edits}},
        else: {:cont, replacement.position + replacement.length}
    end)
    |> case do
      {:error, _reason} = error -> error
      _end_position -> :ok
    end
  end

  defp replace_text(content, replacements) do
    replacements
    |> Enum.sort_by(& &1.position, :desc)
    |> Enum.reduce(content, fn replacement, updated ->
      prefix = binary_part(updated, 0, replacement.position)
      suffix_start = replacement.position + replacement.length
      suffix = binary_part(updated, suffix_start, byte_size(updated) - suffix_start)
      prefix <> replacement.new <> suffix
    end)
  end

  defp apply_files(files) do
    with :ok <- verify_files(files) do
      apply_verified_files(files, [])
    end
  end

  defp apply_verified_files([], _applied), do: :ok

  defp apply_verified_files([file | rest], applied) do
    case File.write(file.path, file.updated) do
      :ok ->
        apply_verified_files(rest, [file | applied])

      {:error, reason} ->
        rollback(applied)
        {:error, {:lsp_write_failed, reason}}
    end
  end

  defp verify_files(files) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      case Hashing.file_sha256_hex(file.path) do
        {:ok, hash} when hash == file.source_hash -> {:cont, :ok}
        {:ok, _hash} -> {:halt, {:error, :stale_lsp_workspace_edit}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rollback(files), do: Enum.each(files, &File.write(&1.path, &1.source))

  defp file_path(uri) do
    case URI.parse(uri) do
      %URI{scheme: "file", path: path} when is_binary(path) -> {:ok, URI.decode(path)}
      _other -> {:error, :unsupported_lsp_uri}
    end
  end

  defp file_uri(path), do: "file://" <> URI.encode(Path.expand(path))

  defp language_id(path) do
    extension = Path.extname(path)
    Map.get(@language_ids, extension, String.trim_leading(extension, "."))
  end

  defp bounded_json(value, max_output_bytes) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) <= max_output_bytes,
      do: encoded,
      else: binary_part(encoded, 0, max_output_bytes)
  end

  defp close_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    if Port.info(port), do: Port.close(port), else: :ok
  rescue
    ArgumentError -> :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
