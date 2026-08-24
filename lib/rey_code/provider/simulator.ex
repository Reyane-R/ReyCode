defmodule ReyCode.Provider.Simulator do
  @moduledoc """
  Seeded provider simulator with bounded jitter and injectable failures.

  The simulator performs exactly one round per `stream/3` call. When the
  scenario defines tool requests, each round returns the next tool call until
  one result per call has been supplied in the conversation; the following
  round returns the final text. The simulator never executes tools.
  """

  @behaviour ReyCode.Provider

  alias ReyCode.Orchestration.Squad
  alias ReyCode.Provider.{Frame, Response, ToolCall}
  alias ReyCode.Provider.Simulator.Scenario

  @impl true
  def stream(runtime, request, emit) do
    scenario = scenario_for(request, runtime)
    sample = Scenario.sample(scenario, request)
    sample = regular_delay(request, runtime, sample)

    case sample.failure do
      :retryable ->
        {:error, Scenario.failure_error(:retryable)}

      :permanent ->
        {:error, Scenario.failure_error(:permanent)}

      :timeout ->
        {:error, Scenario.failure_error(:timeout)}

      :crash ->
        exit(:simulated_provider_crash)

      :invalid_output when request.mode == :squad ->
        emit_result(
          "not valid squad output",
          Response.new(text: "not valid squad output", usage: %{"output_frames" => 1}),
          emit,
          sample.delay_ms,
          scenario.emit_process,
          request.resume_from + 1
        )

      :after_frame ->
        fail_after_frame(request, emit)

      _no_failure ->
        success(request, scenario, sample.delay_ms, emit)
    end
  end

  defp success(request, scenario, delay, emit) do
    case next_tool_call(request, scenario) do
      %ToolCall{} = call ->
        text = if request.mode == :squad, do: "", else: "Simulated tool round for #{call.tool}."
        response = Response.new(text: text, tool_calls: [call], usage: %{"tool_rounds" => true})

        emit_result(text, response, emit, delay, scenario.emit_process, request.resume_from + 1)

      nil ->
        {text, usage} = final_round(request, scenario)

        emit_result(
          text,
          Response.new(text: text, usage: usage),
          emit,
          delay,
          scenario.emit_process,
          request.resume_from + 1
        )
    end
  end

  defp final_round(%{mode: :squad} = request, scenario) do
    output = squad_output(request, scenario)
    {Jason.encode!(output), %{"squad_output" => output}}
  end

  defp final_round(request, scenario) do
    text = final_text(request, scenario)
    {text, %{"tool_results" => tool_result_count(request)}}
  end

  defp next_tool_call(request, scenario) do
    consumed = tool_result_count(request)
    index = consumed + 1

    scenario.tool_requests
    |> Enum.at(index - 1)
    |> case do
      nil ->
        nil

      spec ->
        tool = spec |> Map.get(:tool, Map.get(spec, "tool")) |> to_string()
        arguments = Map.get(spec, :arguments, Map.get(spec, "arguments", %{}))
        ToolCall.new("simulated-tool-#{index}", tool, arguments)
    end
  end

  defp tool_result_count(request) do
    Enum.count(request.messages, &match?(%{role: :tool}, &1))
  end

  defp final_text(request, scenario) do
    if scenario.tool_requests == [] do
      regular_response(request)
    else
      "#{regular_response(request)} (after #{tool_result_count(request)} tool results)"
    end
  end

  defp emit_result(text, %Response{} = response, emit, delay, emit_process, sequence_start) do
    frames = text |> chunks(80) |> Enum.with_index(sequence_start)
    runner = fn -> emit_each(frames, emit, delay) end

    case emit_process do
      :task ->
        runner |> Task.async() |> Task.await(:infinity)

      :caller ->
        runner.()
    end

    {:ok, response}
  end

  defp emit_each(frames, emit, delay) do
    Enum.each(frames, fn {chunk, sequence} ->
      :ok = emit.(%Frame{sequence: sequence, kind: :text_delta, data: %{text: chunk}})
      maybe_sleep(delay)
    end)
  end

  defp fail_after_frame(request, emit) do
    :ok =
      emit.(%Frame{
        sequence: request.resume_from + 1,
        kind: :text_delta,
        data: %{text: "partial simulated output"}
      })

    {:error, Scenario.failure_error(:after_frame)}
  end

  defp squad_output(request, scenario) do
    phase = Squad.phase(request.phase)

    if Squad.gate?(phase) do
      gate_output(request, scenario, phase)
    else
      role = Squad.role(request.participant.id)
      artifacts = Enum.filter(role.artifacts, &(&1 in phase.artifact_kinds))

      outputs =
        Enum.map(artifacts, fn artifact_type ->
          %{
            "artifact_type" => artifact_type,
            "summary" => "#{role.name} completed #{phase.id} for the requested theme.",
            "blockers" => []
          }
        end)

      case outputs do
        [output] -> Map.put(output, "kind", "artifact")
        outputs -> %{"kind" => "artifacts", "artifacts" => outputs}
      end
    end
  end

  defp gate_output(request, scenario, phase) do
    rework? = phase.id == scenario.rework_phase and request.cycle < scenario.leader_rework_rounds

    if rework? do
      %{
        "kind" => "gate",
        "decision" => "rework",
        "target_phase" => phase.rework_phase,
        "reasons" => ["Seeded simulator requested another remediation cycle"]
      }
    else
      %{
        "kind" => "gate",
        "decision" => "approve",
        "target_phase" => nil,
        "reasons" => []
      }
    end
  end

  defp regular_response(request) do
    prompt =
      request.messages
      |> Enum.reverse()
      |> Enum.find_value("the request", fn
        %{role: :user, content: content} -> content
        _message -> nil
      end)

    case {request.mode, request.label, request.participant.id} do
      {:debate, "proposal", _id} ->
        "My proposal for \"#{prompt}\" is to establish the smallest complete path first."

      {:debate, "critique", _id} ->
        "The proposal needs explicit failure recovery and observable acceptance evidence."

      {:debate, "revision", _id} ->
        "Revised recommendation: keep the path narrow, recoverable, and independently verified."

      {_mode, _label, "builder"} ->
        "I would start \"#{prompt}\" with the smallest end-to-end implementation, then use what it reveals to shape the next pass."

      {_mode, _label, "critic"} ->
        "The risky assumption in \"#{prompt}\" is that the first useful path is also the durable one."

      {_mode, _label, _id} ->
        "Another route for \"#{prompt}\" is to prototype contrasting approaches and compare the evidence."
    end
  end

  defp maybe_sleep(0), do: :ok
  defp maybe_sleep(delay), do: Process.sleep(delay)

  # The engine freezes simulator policy into every invocation request. Direct
  # provider callers can still resolve it from the runtime's injected config.
  defp scenario_for(%{simulator_opts: opts}, _runtime) when is_list(opts),
    do: Scenario.new(opts)

  defp scenario_for(_request, runtime), do: scenario_from_config(runtime)

  defp scenario_from_config(runtime) do
    runtime.config.options
    |> Keyword.put_new(:delay_ms, runtime.config.agent_delay_ms)
    |> Scenario.new()
  end

  defp regular_delay(%{mode: :squad}, _runtime, sample), do: sample

  defp regular_delay(request, runtime, sample) do
    delay = request.agent_delay_ms || runtime.config.agent_delay_ms
    %{sample | delay_ms: delay, failure: nil}
  end

  defp chunks(text, size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end
end
