defmodule ReyCode.Provider.Simulator do
  @moduledoc "Seeded provider simulator with bounded jitter and injectable failures."

  @behaviour ReyCode.Provider

  alias ReyCode.Orchestration.Squad
  alias ReyCode.Provider.Frame
  alias ReyCode.Provider.Simulator.Scenario

  @impl true
  def stream(_runtime, request, emit) do
    scenario = Scenario.from_application()
    sample = Scenario.sample(scenario, request)
    sample = regular_delay(request, sample)

    case sample.failure do
      :retryable -> {:error, error("simulated_retryable", true)}
      :permanent -> {:error, error("simulated_permanent", false)}
      :timeout -> {:error, error("simulated_timeout", true)}
      :crash -> exit(:simulated_provider_crash)
      :invalid_output -> emit_result("not valid squad output", %{}, emit, sample.delay_ms)
      :after_frame -> fail_after_frame(request, emit)
      nil -> success(request, scenario, sample.delay_ms, emit)
    end
  end

  defp success(%{mode: :squad} = request, scenario, delay, emit) do
    output = squad_output(request, scenario)
    text = Jason.encode!(output)
    emit_result(text, %{"squad_output" => output}, emit, delay)
  end

  defp success(request, _scenario, delay, emit) do
    emit_result(regular_response(request), %{}, emit, delay)
  end

  defp emit_result(text, metadata, emit, delay) do
    frames = text |> chunks(80) |> Enum.with_index(1)

    Enum.each(frames, fn {chunk, sequence} ->
      :ok = emit.(%Frame{sequence: sequence, kind: :text_delta, data: %{text: chunk}})
      maybe_sleep(delay)
    end)

    {:ok, Map.put(metadata, "usage", %{"output_frames" => length(frames)})}
  end

  defp fail_after_frame(request, emit) do
    :ok =
      emit.(%Frame{
        sequence: request.resume_from + 1,
        kind: :text_delta,
        data: %{text: "partial simulated output"}
      })

    {:error, error("simulated_after_frame", true)}
  end

  defp squad_output(request, scenario) do
    phase = Squad.phase(request.phase)

    if Squad.gate?(phase) do
      gate_output(request, scenario, phase)
    else
      role = Squad.role(request.participant.id)
      artifacts = Enum.filter(role.artifacts, &(&1 in phase.artifacts))

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
        "target_phase" => phase.rework_to,
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

  defp error(category, retryable) do
    %{
      "category" => category,
      "message" => "Injected simulator failure",
      "retryable" => retryable
    }
  end

  defp maybe_sleep(0), do: :ok
  defp maybe_sleep(delay), do: Process.sleep(delay)

  defp regular_delay(%{mode: :squad}, sample), do: sample

  defp regular_delay(request, sample) do
    delay = request.agent_delay_ms || Application.get_env(:rey_code, :agent_delay_ms, 0)
    %{sample | delay_ms: delay, failure: nil}
  end

  defp chunks(text, size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end
end
