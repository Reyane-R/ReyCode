defmodule ReyCode.ProjectInstructions do
  @moduledoc """
  Discovers and freezes bounded project instructions for one Invocation.

  `AGENTS.md` files load from at most eight workspace ancestors, root first.
  Project skills are explicit: `.reycode/skills/enabled` lists up to sixteen
  names, one per line, and each resolves to `<name>/SKILL.md` below the same
  skills directory. Missing discovery files are normal; unreadable or invalid
  configured sources become visible instruction notices rather than silent
  fallback.
  """

  alias ReyCode.Hashing
  alias ReyCode.Security.CanonicalPath

  @max_ancestors 8
  @max_sources 24
  @max_source_bytes 32_768
  @max_total_bytes 131_072
  @max_enabled_bytes 4_096
  @max_skills 16
  @skill_name_pattern ~r/\A[A-Za-z0-9_-]+\z/

  defmodule Capture do
    @moduledoc false
    @enforce_keys [:content, :digest, :sources]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            content: String.t(),
            digest: String.t() | nil,
            sources: [String.t()]
          }
  end

  @doc "Captures the current bounded instruction set for a workspace."
  @spec capture(String.t()) :: Capture.t()
  def capture(workspace) do
    sources = agent_sources(workspace) ++ skill_sources(workspace)
    {sections, paths, _bytes} = load_sources(Enum.take(sources, @max_sources))
    content = Enum.join(sections, "\n\n")

    %Capture{
      content: content,
      digest: if(content == "", do: nil, else: Hashing.sha256_hex(content)),
      sources: paths
    }
  end

  defp agent_sources(workspace) do
    workspace
    |> Path.expand()
    |> ancestors([])
    |> Enum.reverse()
    |> Enum.take(@max_ancestors)
    |> Enum.reverse()
    |> Enum.map(&%{path: Path.join(&1, "AGENTS.md"), kind: :optional})
  end

  defp ancestors(path, paths) do
    parent = Path.dirname(path)
    next = [path | paths]
    if parent == path, do: next, else: ancestors(parent, next)
  end

  defp skill_sources(workspace) do
    skills_root = Path.join([Path.expand(workspace), ".reycode", "skills"])
    enabled_path = Path.join(skills_root, "enabled")

    case bounded_read(enabled_path, @max_enabled_bytes, :optional) do
      :missing ->
        []

      {:ok, enabled} ->
        enabled
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.take(@max_skills)
        |> Enum.map(&skill_source(&1, skills_root))

      {:notice, notice} ->
        [%{notice: notice, path: enabled_path}]
    end
  end

  defp skill_source(name, skills_root) do
    if Regex.match?(@skill_name_pattern, name) do
      path = Path.join([skills_root, name, "SKILL.md"])

      case contained_skill?(path, skills_root) do
        true -> %{path: path, kind: :required}
        false -> %{notice: "Rejected skill outside project skills directory: #{name}", path: path}
      end
    else
      %{notice: "Rejected invalid project skill name: #{name}", path: skills_root}
    end
  end

  defp contained_skill?(path, root) do
    case {CanonicalPath.resolve(root), CanonicalPath.resolve(path)} do
      {{:ok, canonical_root}, {:ok, canonical_path}} ->
        contained?(canonical_path, canonical_root)

      {{:ok, _canonical_root}, {:error, :enoent}} ->
        true

      _error ->
        false
    end
  end

  defp contained?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp load_sources(sources) do
    Enum.reduce_while(sources, {[], [], 0}, fn source, acc ->
      source
      |> load_source(@max_source_bytes)
      |> append_source(acc)
    end)
  end

  defp append_source(:missing, acc), do: {:cont, acc}

  defp append_source({_kind, section, path}, {sections, paths, bytes}) do
    next_bytes = bytes + byte_size(section)

    if next_bytes <= @max_total_bytes,
      do: {:cont, {sections ++ [section], paths ++ [path], next_bytes}},
      else: {:halt, {sections ++ [limit_notice()], paths, bytes}}
  end

  defp load_source(%{notice: notice, path: path}, _max_bytes),
    do: {:notice, instruction_notice(notice), path}

  defp load_source(%{path: path, kind: kind}, max_bytes) do
    case bounded_read(path, max_bytes, kind) do
      :missing -> :missing
      {:ok, content} -> {:ok, section(path, content), path}
      {:notice, notice} -> {:notice, instruction_notice(notice), path}
    end
  end

  defp bounded_read(path, max_bytes, kind) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        case File.read(path) do
          {:ok, content} -> validate_content(path, content)
          {:error, reason} -> {:notice, "Could not read #{path}: #{reason}"}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:notice, "Instruction source exceeds #{max_bytes} bytes: #{path}"}

      {:ok, _stat} ->
        {:notice, "Instruction source is not a regular file: #{path}"}

      {:error, :enoent} when kind == :optional ->
        :missing

      {:error, :enoent} ->
        {:notice, "Configured instruction source is missing: #{path}"}

      {:error, reason} ->
        {:notice, "Could not inspect #{path}: #{reason}"}
    end
  end

  defp validate_content(path, content) do
    if String.valid?(content) and not String.contains?(content, <<0>>),
      do: {:ok, content},
      else: {:notice, "Instruction source is not UTF-8 text: #{path}"}
  end

  defp section(path, content), do: "Project instructions from #{path}:\n\n" <> content
  defp instruction_notice(notice), do: "Project instruction notice:\n\n" <> notice

  defp limit_notice do
    "Project instruction notice:\n\nInstruction sources exceeded #{@max_total_bytes} total bytes; remaining sources were not loaded."
  end
end
