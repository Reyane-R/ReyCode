defmodule ReyCode.CLI.Run do
  @moduledoc "Bounded argument, stdin, startup, and output handling for `reycode run`."

  alias ReyCode.{Application, OneShot}
  alias ReyCode.Orchestration.{Engine, Validation}

  @default_timeout_ms 600_000
  @switches [prompt: :string, workspace: :string, json: :boolean, timeout_ms: :integer]
  @aliases [p: :prompt]

  @type parsed_options :: %{
          required(:prompt) => String.t(),
          required(:workspace) => String.t(),
          required(:timeout_ms) => pos_integer(),
          required(:json?) => boolean()
        }

  @doc "Parses one prompt from `-p`, positional arguments, or bounded piped stdin."
  @spec parse([String.t()], keyword()) :: {:ok, parsed_options()} | {:error, String.t()}
  def parse(argv, opts \\ []) do
    stdin_reader = Keyword.get(opts, :stdin_reader, &read_stdin/0)
    {parsed, arguments, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    with :ok <- validate_options(invalid, parsed, arguments),
         {:ok, prompt} <- prompt(parsed[:prompt], arguments, stdin_reader),
         {:ok, prompt} <- validate_prompt(prompt),
         {:ok, workspace} <- validate_workspace(parsed[:workspace] || File.cwd!()),
         {:ok, timeout_ms} <- validate_timeout(parsed[:timeout_ms] || @default_timeout_ms) do
      {:ok,
       %{
         prompt: prompt,
         workspace: workspace,
         timeout_ms: timeout_ms,
         json?: !!parsed[:json]
       }}
    end
  end

  @doc "Runs the command and returns already-rendered stdout or stderr content."
  @spec execute([String.t()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(argv, opts \\ []) do
    runner = Keyword.get(opts, :runner, &OneShot.run/2)

    with {:ok, options} <- parse(argv, opts),
         {:ok, engine} <- engine(opts) do
      run_options = %{
        prompt: options.prompt,
        workspace: options.workspace,
        timeout_ms: options.timeout_ms
      }

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
      "[--workspace DIR] [--json] [--timeout-ms N]"
  end

  defp validate_options([], parsed, arguments) do
    if is_binary(parsed[:prompt]) and arguments != [],
      do: {:error, "choose either -p or positional prompt text\n#{usage()}"},
      else: :ok
  end

  defp validate_options(_invalid, _parsed, _arguments), do: {:error, usage()}

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
  defp render({:ok, report}, false), do: {:ok, report.response}
  defp render({:error, report}, true), do: {:error, Jason.encode!(json_report(report))}
  defp render({:error, report}, false), do: {:error, "reycode run: #{report.error}"}

  defp json_report(report) do
    report
    |> Map.update!(:outcome, &to_string/1)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end
end
