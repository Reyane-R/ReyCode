defmodule ReyCode.CLI.Run do
  @moduledoc "Bounded argument, stdin, startup, and output handling for `reycode run`."

  alias ReyCode.{Application, OneShot, VerifiedChange}
  alias ReyCode.Orchestration.{Engine, Validation}

  @default_timeout_ms 600_000
  @switches [
    prompt: :string,
    workspace: :string,
    json: :boolean,
    timeout_ms: :integer,
    verified: :boolean,
    check: [:keep, :string],
    max_repair_count: :integer,
    check_timeout_ms: :integer,
    testing_provider: :string,
    testing_model: :string,
    release_provider: :string,
    release_model: :string
  ]
  @aliases [p: :prompt]

  @type verified_options :: %{
          required(:commands) => [String.t()],
          required(:max_repair_count) => non_neg_integer(),
          required(:check_timeout_ms) => pos_integer(),
          optional(:testing_provider) => String.t(),
          optional(:testing_model) => String.t(),
          optional(:release_provider) => String.t(),
          optional(:release_model) => String.t()
        }

  @type parsed_options :: %{
          required(:prompt) => String.t(),
          required(:workspace) => String.t(),
          required(:timeout_ms) => pos_integer(),
          required(:json?) => boolean(),
          optional(:verified) => verified_options()
        }

  @doc "Parses one prompt from `-p`, positional arguments, or bounded piped stdin."
  @spec parse([String.t()], keyword()) :: {:ok, parsed_options()} | {:error, String.t()}
  def parse(argv, opts \\ []) do
    stdin_reader = Keyword.get(opts, :stdin_reader, &read_stdin/0)
    {parsed, arguments, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    with :ok <- validate_options(invalid, parsed, arguments),
         {:ok, verified} <- verified_options(parsed),
         {:ok, prompt} <- prompt(parsed[:prompt], arguments, stdin_reader),
         {:ok, prompt} <- validate_prompt(prompt),
         {:ok, workspace} <- validate_workspace(parsed[:workspace] || File.cwd!()),
         {:ok, timeout_ms} <- validate_timeout(parsed[:timeout_ms] || @default_timeout_ms) do
      options =
        Map.merge(
          %{
            prompt: prompt,
            workspace: workspace,
            timeout_ms: timeout_ms,
            json?: !!parsed[:json]
          },
          verified
        )

      validate_run_options(options)
    end
  end

  defp validate_run_options(%{verified: verified} = options) do
    with :ok <- VerifiedChange.validate_options(Map.merge(options, verified)), do: {:ok, options}
  end

  defp validate_run_options(options), do: {:ok, options}

  @doc "Runs the command and returns already-rendered stdout or stderr content."
  @spec execute([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(argv, opts \\ []) do
    with {:ok, options} <- parse(argv, opts),
         {:ok, engine} <- engine(opts) do
      default_runner =
        if Map.has_key?(options, :verified), do: &VerifiedChange.run/2, else: &OneShot.run/2

      runner = Keyword.get(opts, :runner, default_runner)

      run_options = %{
        prompt: options.prompt,
        workspace: options.workspace,
        timeout_ms: options.timeout_ms
      }

      run_options = Map.merge(run_options, Map.get(options, :verified, %{}))
      render(runner.(run_options, engine), options.json?)
    end
  end

  @doc false
  @spec main([String.t()], (non_neg_integer() -> no_return()), keyword()) :: no_return()
  def main(argv, halt \\ &System.halt/1, opts \\ []) do
    case execute(argv, opts) do
      {:ok, output} ->
        IO.puts(output)
        halt.(0)

      {:error, output} ->
        IO.puts(:stderr, output)
        halt.(1)
    end
  end

  @doc "Returns command usage shared by release and Mix entry points."
  @spec usage() :: String.t()
  def usage do
    "Usage: reycode run [-p TEXT | TEXT ... | < stdin] " <>
      "[--workspace DIR] [--json] [--timeout-ms N] " <>
      "[--verified --check COMMAND [--check COMMAND ...] " <>
      "[--max-repair-count 0..3] [--check-timeout-ms 1..600000] " <>
      "[--testing-provider ID --testing-model MODEL] " <>
      "[--release-provider ID --release-model MODEL]]\n" <>
      "--verified requires 1..8 nonblank UTF-8 checks, each at most 4096 bytes; " <>
      "--timeout-ms is capped at 3600000 in verified mode.\n" <>
      "The optional cheap-model workflow stages run report-only: Testing analyzes\n" <>
      "failed checks for the main model, Release drafts commit/PR metadata. No stage\n" <>
      "can edit files or authorize operations. Providers must be OpenAI-compatible,\n" <>
      "local (ollama, lmstudio), or simulator.\n" <>
      "Defaults: --max-repair-count 1, --check-timeout-ms 120000.\n" <>
      "WARNING: --check explicitly authorizes bounded HOST shell command execution, not a sandbox."
  end

  defp validate_options([], parsed, arguments) do
    if is_binary(parsed[:prompt]) and arguments != [],
      do: {:error, "choose either -p or positional prompt text\n#{usage()}"},
      else: :ok
  end

  defp validate_options(_invalid, _parsed, _arguments), do: {:error, usage()}

  defp verified_options(parsed) do
    if parsed[:verified] do
      validate_verified_options(parsed)
    else
      workflow_keys = [
        :testing_provider,
        :testing_model,
        :release_provider,
        :release_model
      ]

      if Enum.any?(
           [:check, :max_repair_count, :check_timeout_ms | workflow_keys],
           &Keyword.has_key?(parsed, &1)
         ),
         do:
           {:error,
            "--check, --max-repair-count, --check-timeout-ms and the workflow\n" <>
              workflow_usage() <> "require --verified"},
         else: {:ok, %{}}
    end
  end

  defp workflow_usage do
    "--testing-provider/--testing-model and --release-provider/--release-model\n" <>
      "flags"
  end

  defp validate_verified_options(parsed) do
    commands = Keyword.get_values(parsed, :check)
    max_repair_count = Keyword.get(parsed, :max_repair_count, 1)
    check_timeout_ms = Keyword.get(parsed, :check_timeout_ms, 120_000)
    timeout_ms = Keyword.get(parsed, :timeout_ms, @default_timeout_ms)

    workflow = workflow_options(parsed)

    cond do
      length(commands) not in 1..8 or not Enum.all?(commands, &valid_check?/1) ->
        {:error,
         "--verified requires 1..8 nonblank valid UTF-8 --check commands of at most 4096 bytes each"}

      max_repair_count not in 0..3 ->
        {:error, "--max-repair-count must be in 0..3"}

      check_timeout_ms not in 1..600_000 ->
        {:error, "--check-timeout-ms must be in 1..600000"}

      timeout_ms not in 1..3_600_000 ->
        {:error, "--timeout-ms must be in 1..3600000 with --verified"}

      workflow == :error ->
        {:error,
         "--testing-provider/--testing-model and --release-provider/--release-model must be\n" <>
           "given as complete pairs of nonempty strings"}

      true ->
        {:ok,
         %{
           verified:
             %{
               commands: commands,
               max_repair_count: max_repair_count,
               check_timeout_ms: check_timeout_ms
             }
             |> Map.merge(workflow)
         }}
    end
  end

  defp workflow_options(parsed) do
    pairs = [
      testing: {Keyword.get(parsed, :testing_provider), Keyword.get(parsed, :testing_model)},
      release: {Keyword.get(parsed, :release_provider), Keyword.get(parsed, :release_model)}
    ]

    complete? =
      Enum.all?(pairs, fn {_stage, {provider, model}} ->
        (is_binary(provider) and is_binary(model)) or (is_nil(provider) and is_nil(model))
      end)

    if complete? do
      pairs
      |> Enum.flat_map(fn
        {_stage, {nil, nil}} ->
          []

        {stage, {provider, model}} ->
          [{:"#{stage}_provider", provider}, {:"#{stage}_model", model}]
      end)
      |> Map.new()
    else
      :error
    end
  end

  defp valid_check?(command) do
    byte_size(command) <= 4096 and String.valid?(command) and String.trim(command) != ""
  end

  defp prompt(value, [], _reader) when is_binary(value), do: {:ok, value}
  defp prompt(nil, arguments, _reader) when arguments != [], do: {:ok, Enum.join(arguments, " ")}
  defp prompt(nil, [], reader), do: reader.()

  defp validate_prompt(prompt) when is_binary(prompt) do
    case Validation.message(prompt) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, :empty_message} ->
        {:error, "prompt is empty\n#{usage()}"}

      {:error, :invalid_message} ->
        {:error, "prompt exceeds #{Validation.message_max_bytes()} bytes"}
    end
  end

  defp validate_prompt(_prompt), do: {:error, usage()}

  defp validate_workspace(path) do
    workspace = Path.expand(path)

    if File.dir?(workspace),
      do: {:ok, workspace},
      else: {:error, "workspace is not a directory: #{workspace}"}
  end

  defp validate_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: {:ok, timeout_ms}

  defp validate_timeout(_timeout_ms), do: {:error, "--timeout-ms must be positive"}

  defp read_stdin do
    if terminal_input?() do
      {:error, usage()}
    else
      case IO.binread(:stdio, Validation.message_max_bytes() + 1) do
        data when is_binary(data) -> {:ok, data}
        :eof -> {:error, "prompt is empty\n#{usage()}"}
        {:error, reason} -> {:error, "could not read stdin: #{reason}"}
      end
    end
  end

  defp terminal_input? do
    match?({:ok, _columns}, :io.columns(:standard_io))
  rescue
    _error -> false
  end

  @spec engine(keyword()) :: {:ok, GenServer.server()} | {:error, String.t()}
  defp engine(opts) do
    case Keyword.get(opts, :engine) do
      nil -> start_application_without_tui()
      engine -> {:ok, engine}
    end
  end

  defp start_application_without_tui do
    case Application.ensure_started_without_tui() do
      {:ok, _applications} -> {:ok, Engine}
      {:error, reason} -> {:error, "could not start ReyCode: #{inspect(reason)}"}
    end
  end

  defp render({:ok, report}, true), do: {:ok, Jason.encode!(json_report(report))}

  defp render({:ok, %{verification: _} = report}, false),
    do: {:ok, verification_summary(report) <> "\n\nAssistant response:\n" <> report.response}

  defp render({:ok, report}, false), do: {:ok, report.response}
  defp render({:error, report}, true), do: {:error, Jason.encode!(json_report(report))}

  defp render({:error, %{verification: verification} = report}, false) do
    details = if verification == %{}, do: "", else: "\n" <> verification_summary(report)
    {:error, "reycode run: #{report.error}" <> details}
  end

  defp render({:error, report}, false), do: {:error, "reycode run: #{report.error}"}

  defp verification_summary(report) do
    evidence = report.verification

    summary =
      evidence
      |> Map.drop(["patch", "prompt", "baseline", "checks"])
      |> Map.put("patch_bytes", byte_size(Map.get(evidence, "patch", "")))
      |> Map.put("baseline", check_summary(Map.get(evidence, "baseline", [])))
      |> Map.put("checks", check_summary(Map.get(evidence, "checks", [])))

    "Verification: #{report.outcome}; source not automatically applied.\n" <>
      "session_id: #{Jason.encode!(Map.get(report, :session_id))}\n" <>
      "turn_id: #{Jason.encode!(Map.get(report, :turn_id))}\n" <>
      "verification: #{Jason.encode!(summary, pretty: true)}\n" <>
      "Use --json for the full retained patch and check output; Session exports retain the evidence."
  end

  defp check_summary(checks), do: Enum.map(checks, &Map.drop(&1, ["output"]))

  defp json_report(%{verification: _verification} = report), do: report

  defp json_report(report) do
    report
    |> Map.update!(:outcome, &to_string/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
