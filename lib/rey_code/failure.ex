defmodule ReyCode.Failure do
  @moduledoc "Typed internal failure converted to string-keyed maps only at wire seams."

  @known_categories ~w(
    authentication_error authentication_failed cancelled command_failed executable_changed
    external_failure incomplete_tool_call internal interrupted invalid_executable invalid_runtime
    invalid_squad_output invalid_workspace launch_failed missing_credentials output_too_large
    prompt_too_large protocol_error provider_error provider_unavailable rate_limit rate_limited
    request_cancelled request_failed response_too_large server_error simulated_after_frame
    simulated_permanent simulated_retryable simulated_timeout timeout tool_calls_unsupported
    tool_denied unknown_failure
    worker_exit worker_start_failed
  )a
  @category_by_wire Map.new(@known_categories, &{Atom.to_string(&1), &1})

  @enforce_keys [:category, :message, :retryable?]
  defstruct [:category, :message, :cause, retryable?: false]

  @type t :: %__MODULE__{
          category: atom(),
          message: String.t(),
          retryable?: boolean(),
          cause: term()
        }

  @spec new(atom(), String.t(), boolean(), term()) :: t()
  def new(category, message, retryable? \\ false, cause \\ nil)
      when is_atom(category) and is_binary(message) and is_boolean(retryable?) do
    %__MODULE__{category: category, message: message, retryable?: retryable?, cause: cause}
  end

  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{retryable?: retryable?}), do: retryable?

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = failure) do
    %{
      "category" => Atom.to_string(failure.category),
      "message" => failure.message,
      "retryable" => failure.retryable?
    }
  end

  @spec from_wire(term()) :: {:ok, t()} | {:error, :invalid_failure}
  def from_wire(%{"category" => category, "message" => message, "retryable" => retryable?})
      when is_binary(category) and is_binary(message) and is_boolean(retryable?) do
    case Map.fetch(@category_by_wire, category) do
      {:ok, category} -> {:ok, new(category, message, retryable?)}
      :error -> {:ok, new(:unknown_failure, message, retryable?, category)}
    end
  end

  def from_wire(_failure), do: {:error, :invalid_failure}

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = failure), do: failure

  def from_map(failure) when is_map(failure) do
    if Map.has_key?(failure, :category) do
      struct!(__MODULE__, Map.take(failure, [:category, :message, :retryable?, :cause]))
    else
      case from_wire(failure) do
        {:ok, failure} -> failure
        {:error, :invalid_failure} -> raise ArgumentError, "invalid projected failure"
      end
    end
  end
end
