defmodule ReyCode.TUI.Completion do
  @moduledoc """
  Owns bounded contextual composer completion and command parsing.

  Completion changes presentation state only. Dynamic candidates carry stable
  source identities and are revalidated against the latest immutable snapshots
  when the draft is submitted.
  """

  alias ReyCode.Security.CanonicalPath

  @default_max_candidates 50
  @default_scan_timeout_ms 50

  defmodule Candidate do
    @moduledoc false
    @enforce_keys [
      :id,
      :kind,
      :label,
      :detail,
      :replacement_start,
      :replacement_length,
      :insertion,
      :suffix,
      :dynamic_id,
      :value,
      :payload
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            kind: atom(),
            label: String.t(),
            detail: String.t(),
            replacement_start: non_neg_integer(),
            replacement_length: non_neg_integer(),
            insertion: String.t(),
            suffix: String.t(),
            dynamic_id: String.t() | nil,
            value: String.t(),
            payload: term()
          }
  end

  defmodule Context do
    @moduledoc false
    @enforce_keys [
      :draft,
      :cursor,
      :commands,
      :participants,
      :providers,
      :sessions,
      :workspace,
      :max_candidates,
      :scan_timeout_ms
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            draft: String.t(),
            cursor: non_neg_integer(),
            commands: [map()],
            participants: [map()],
            providers: map(),
            sessions: [map()],
            workspace: String.t() | nil,
            max_candidates: pos_integer(),
            scan_timeout_ms: pos_integer()
          }
  end

  @type parsed :: %{
          command: String.t(),
          action: atom(),
          argument: term(),
          dynamic_id: String.t() | nil,
          kind: atom() | nil
        }

  @doc "Builds one immutable completion context from current presentation snapshots."
  @spec new(keyword()) :: Context.t()
  def new(opts) do
    draft = Keyword.fetch!(opts, :draft)

    %Context{
      draft: draft,
      cursor: Keyword.get(opts, :cursor, String.length(draft)),
      commands: Keyword.fetch!(opts, :commands),
      participants: Keyword.get(opts, :participants, []),
      providers: Keyword.get(opts, :providers, %{}),
      sessions: Keyword.get(opts, :sessions, []),
      workspace: Keyword.get(opts, :workspace),
      max_candidates: Keyword.get(opts, :max_candidates, @default_max_candidates),
      scan_timeout_ms: Keyword.get(opts, :scan_timeout_ms, @default_scan_timeout_ms)
    }
  end

  @doc "Returns bounded, deterministically ranked candidates at the cursor."
  @spec candidates(Context.t()) :: [Candidate.t()]
  def candidates(%Context{} = context) do
    position = token_position(context.draft, context.cursor)

    context
    |> source(position)
    |> rank(position.query)
    |> Enum.take(context.max_candidates)
    |> Enum.map(&candidate(&1, position))
  end

  @doc "Accepts one candidate by replacing only its declared grapheme range."
  @spec accept(Context.t(), Candidate.t()) :: {:ok, String.t(), non_neg_integer(), String.t()}
  def accept(%Context{draft: draft}, %Candidate{} = candidate) do
    graphemes = String.graphemes(draft)
    {before, rest} = Enum.split(graphemes, candidate.replacement_start)
    {_replaced, after_replacement} = Enum.split(rest, candidate.replacement_length)
    inserted = String.graphemes(candidate.insertion <> candidate.suffix)
    next = IO.iodata_to_binary(before ++ inserted ++ after_replacement)
    cursor = candidate.replacement_start + length(inserted)
    {:ok, next, cursor, candidate.id}
  end

  @doc "Parses and revalidates a submitted command against current snapshots."
  @spec parse(Context.t()) :: {:ok, parsed()} | {:error, atom()}
  def parse(%Context{} = context) do
    with {:ok, tokens} <- split(context.draft),
         [command_name | arguments] <- tokens,
         %{} = command <- Enum.find(context.commands, &(&1.command == command_name)) do
      parse_arguments(context, command, arguments)
    else
      [] -> {:error, :empty_command}
      nil -> {:error, :unknown_command}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Moves a selected candidate index with wraparound."
  @spec move(non_neg_integer(), non_neg_integer(), integer()) :: non_neg_integer()
  def move(index, 0, _offset), do: index
  def move(index, count, offset), do: Integer.mod(index + offset, count)

  defp source(context, %{command: nil} = position), do: command_source(context, position)

  defp source(context, %{command: command_name} = position) do
    case Enum.find(context.commands, &(&1.command == command_name)) do
      %{argument: :participant} -> participant_source(context, position)
      %{argument: :model} -> model_source(context, position)
      %{argument: :session} -> session_source(context, position)
      %{argument: :directory} -> directory_source(context, position)
      _other -> []
    end
  end

  defp command_source(context, _position) do
    Enum.map(context.commands, fn command ->
      %{
        id: "command:" <> command.command,
        kind: :command,
        label: command.command,
        detail: command.description,
        insertion: command.command,
        suffix: if(Map.has_key?(command, :argument), do: " ", else: ""),
        dynamic_id: nil,
        value: command.command,
        payload: command
      }
    end)
  end

  defp participant_source(context, _position) do
    context.participants
    |> Enum.filter(&(&1.kind == :task))
    |> Enum.map(fn participant ->
      source_entry(
        "participant:" <> participant.id,
        :participant,
        participant.name,
        participant.perspective,
        participant.id,
        participant.id
      )
    end)
  end

  defp model_source(context, _position) do
    context.providers
    |> Map.values()
    |> Enum.filter(&(&1.status == :configured))
    |> Enum.sort_by(& &1.name)
    |> Enum.flat_map(fn provider ->
      Enum.map(provider.models, fn model ->
        value = to_string(provider.id) <> "/" <> model

        source_entry(
          "model:" <> value,
          :model,
          value,
          provider.name,
          value,
          %{provider: provider.id, model: model}
        )
      end)
    end)
  end

  defp session_source(context, _position) do
    context.sessions
    |> Enum.filter(&(&1.message_order != []))
    |> Enum.map(fn session ->
      source_entry(
        "session:" <> session.id,
        :session,
        session.title,
        Path.basename(session.workspace),
        session.id,
        session.id
      )
    end)
  end

  defp directory_source(%Context{workspace: nil}, _position), do: []

  defp directory_source(context, position) do
    partial = unquote_token(position.query)
    task = Task.async(fn -> scan_directories(context.workspace, partial) end)

    entries =
      case Task.yield(task, context.scan_timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, values} -> values
        _other -> []
      end

    Enum.map(entries, fn relative ->
      source_entry(
        "directory:" <> relative,
        :directory,
        relative,
        "workspace directory",
        relative,
        relative
      )
    end)
  end

  defp scan_directories(workspace, partial) do
    with {:ok, root} <- CanonicalPath.resolve(workspace),
         {parent_input, prefix} <- directory_parent(root, partial),
         {:ok, parent} <- CanonicalPath.resolve(parent_input),
         true <- contained?(parent, root),
         {:ok, names} <- File.ls(parent) do
      names
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()
      |> Enum.filter(fn name -> File.dir?(Path.join(parent, name)) end)
      |> Enum.map(fn name ->
        parent
        |> Path.join(name)
        |> Path.relative_to(root)
        |> Kernel.<>("/")
      end)
    else
      _other -> []
    end
  end

  defp directory_parent(root, ""), do: {root, ""}

  defp directory_parent(root, partial) do
    target = if Path.type(partial) == :absolute, do: partial, else: Path.join(root, partial)

    if String.ends_with?(partial, "/") do
      {target, ""}
    else
      {Path.dirname(target), Path.basename(target)}
    end
  end

  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp source_entry(id, kind, label, detail, value, payload) do
    %{
      id: id,
      kind: kind,
      label: label,
      detail: detail,
      insertion: quote_if_needed(value),
      suffix: "",
      dynamic_id: id,
      value: value,
      payload: payload
    }
  end

  defp candidate(entry, position) do
    %Candidate{
      id: entry.id,
      kind: entry.kind,
      label: entry.label,
      detail: entry.detail,
      replacement_start: position.start,
      replacement_length: position.length,
      insertion: entry.insertion,
      suffix: entry.suffix,
      dynamic_id: entry.dynamic_id,
      value: entry.value,
      payload: entry.payload
    }
  end

  defp rank(entries, query) do
    query = query |> unquote_token() |> String.downcase()

    entries
    |> Enum.map(&{&1, fuzzy_rank(&1.label, query)})
    |> Enum.reject(fn {_entry, result} -> is_nil(result) end)
    |> Enum.sort_by(fn {entry, result} -> {result, String.downcase(entry.label), entry.id} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp fuzzy_rank(label, query) do
    label = String.downcase(label)

    cond do
      query == "" -> 4
      label == query -> 0
      String.starts_with?(label, query) -> 1
      String.contains?(label, query) -> 2
      subsequence?(String.graphemes(label), String.graphemes(query)) -> 3
      true -> nil
    end
  end

  defp subsequence?(_label, []), do: true
  defp subsequence?([], _query), do: false
  defp subsequence?([same | label], [same | query]), do: subsequence?(label, query)
  defp subsequence?([_other | label], query), do: subsequence?(label, query)

  defp token_position(draft, cursor) do
    graphemes = String.graphemes(draft)
    cursor = cursor |> max(0) |> min(length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    start = token_start(left)
    finish = cursor + token_tail_length(right)
    token = graphemes |> Enum.slice(start, finish - start) |> IO.iodata_to_binary()
    command = if String.starts_with?(token, "/"), do: nil, else: command_before(graphemes, start)
    %{start: start, length: finish - start, query: token, command: command}
  end

  defp token_start(left) do
    left
    |> Enum.with_index()
    |> Enum.reduce(0, fn {grapheme, index}, start ->
      if whitespace?(grapheme), do: index + 1, else: start
    end)
  end

  defp token_tail_length(right), do: Enum.find_index(right, &whitespace?/1) || length(right)

  defp command_before(_graphemes, 0), do: nil

  defp command_before(graphemes, _start) do
    graphemes
    |> Enum.take_while(&(not whitespace?(&1)))
    |> IO.iodata_to_binary()
  end

  defp whitespace?(grapheme), do: String.match?(grapheme, ~r/^\s$/u)

  defp parse_arguments(context, command, arguments) do
    case {Map.get(command, :argument), arguments} do
      {nil, []} -> parsed(command, nil, nil, nil)
      {nil, _arguments} -> {:error, :unexpected_argument}
      {:text, []} -> {:error, :missing_argument}
      {:text, values} -> parsed(command, Enum.join(values, " "), nil, :text)
      {_kind, []} -> parsed(command, nil, nil, nil)
      {kind, [argument]} -> revalidate(context, command, kind, argument)
      {_kind, _arguments} -> {:error, :unexpected_argument}
    end
  end

  defp revalidate(context, command, kind, argument) do
    position = %{command: command.command, query: argument, start: 0, length: 0}

    case Enum.find(source(context, position), fn entry ->
           entry.value == argument or entry.label == argument
         end) do
      nil -> {:error, :stale_argument}
      entry -> parsed(command, entry.payload, entry.dynamic_id, kind)
    end
  end

  defp parsed(command, argument, dynamic_id, kind) do
    {:ok,
     %{
       command: command.command,
       action: command.action,
       argument: argument,
       dynamic_id: dynamic_id,
       kind: kind
     }}
  end

  defp split(draft) do
    {:ok, OptionParser.split(String.trim(draft))}
  rescue
    OptionParser.ParseError -> {:error, :malformed_command}
  end

  defp quote_if_needed(value) do
    value = to_string(value)
    if String.match?(value, ~r/\s/u), do: inspect(value), else: value
  end

  defp unquote_token(token) do
    token
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end
end
