defmodule ReyCode.Event do
  @moduledoc "A versioned durable fact stored in global sequence order."

  alias ReyCode.{Failure, JSON}

  @schema_version 2

  @enforce_keys [
    :id,
    :sequence,
    :schema_version,
    :type,
    :aggregate_type,
    :aggregate_id,
    :data,
    :recorded_at
  ]
  defstruct [
    :id,
    :sequence,
    :schema_version,
    :type,
    :aggregate_type,
    :aggregate_id,
    :room_id,
    :correlation_id,
    :causation_id,
    :data,
    :recorded_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          sequence: pos_integer(),
          schema_version: pos_integer(),
          type: type(),
          aggregate_type: atom(),
          aggregate_id: String.t(),
          room_id: String.t() | nil,
          correlation_id: String.t() | nil,
          causation_id: String.t() | nil,
          data: map(),
          recorded_at: String.t()
        }

  @types ~w(
    room_created session_forked context_compacted participant_added participant_configured message_posted turn_queued turn_started assistant_message_opened
    invocation_started invocation_steering_requested provider_frame_recorded invocation_completed invocation_failed invocation_cancelled
    turn_completed snapshot_recorded squad_configured squad_stage_entered squad_decision_recorded
    squad_artifact_recorded squad_retry_scheduled squad_role_configured squad_directive_added
    gate_review_requested gate_resolved squad_budget_extended tool_ask_requested tool_ask_resolved
    provider_round_recorded tool_run_requested tool_run_approval_resolved tool_run_started
    tool_run_completed tool_run_failed tool_run_interrupted delegation_opened
    delegation_merge_requested delegation_merge_resolved peer_message_sent
    operator_question_asked operator_question_answered invocation_plan_updated participant_tier_configured
  )a
  @type type ::
          unquote(
            @types
            |> Enum.reduce(fn type, union -> {:|, [], [union, type]} end)
          )
  @type_lookup Map.new(@types, &{Atom.to_string(&1), &1})
  @known_types MapSet.new(@types)

  # Field rules validate JSON-normalized values (string keys, no atoms).
  # `:id` marks identity strings the projector relies on being non-empty;
  # `:text` accepts any string body. Optional fields are legacy-tolerant:
  # schema-v2 events written before a field existed must keep decoding.
  @type rule ::
          :id
          | :text
          | :nullable_text
          | :wire_map
          | :nullable_wire_map
          | :text_list
          | :map_list
          | :non_negative_integer
          | :positive_integer
          | :boolean
          | {:one_of, [String.t()]}
          | :participant_list
          | :participant
          | :failure
          | :snapshot_binary

  # Wire values come from the closed orchestration mode contract; retired
  # wire values stay valid here so historical turns keep replaying.
  @durable_modes Enum.map(ReyCode.Orchestration.Mode.all(), & &1.wire) ++
                   ReyCode.Orchestration.Mode.retired_wire_values()
  @outcomes ~w(completed partial failed reworked cancelled)
  @gate_decisions ~w(approve rework abort)
  @tool_decisions ~w(approve deny)
  @authorizations ~w(allow ask denied)
  @release_authorities ~w(human leader)
  @participant_kinds ~w(primary task legacy)
  @input_kinds ~w(operator follow_up detached)
  @model_tiers ~w(smol default slow)
  @merge_decisions ~w(apply discard)
  @retry_kinds ~w(provider_retry rework)

  @frame_kinds ~w(
    text_delta agent_note usage session_started tool_started tool_completed tool_request tool_result
  )

  @invocation_identity %{"invocation_id" => :id, "message_id" => :id}
  @turn_session_wire_identity %{"turn_id" => :id, "room_id" => :id}

  @gate_contract %{
    required:
      Map.merge(@turn_session_wire_identity, %{
        "seat_id" => :id,
        "decision" => {:one_of, @gate_decisions},
        "phase" => :text,
        "cycle" => :non_negative_integer
      }),
    optional: %{"target_phase" => :nullable_text, "reasons" => :text_list}
  }

  @contract %{
    room_created: %{
      required: %{
        "room_id" => :id,
        "slug" => :id,
        "title" => :text,
        "workspace" => :text,
        "participants" => :participant_list
      },
      optional: %{}
    },
    context_compacted: %{
      required: %{
        "room_id" => :id,
        "through_sequence" => :non_negative_integer,
        "summary" => :text,
        "source_message_count" => :non_negative_integer,
        "source_bytes" => :non_negative_integer,
        "summary_bytes" => :non_negative_integer,
        "generator" => :id
      },
      optional: %{}
    },
    session_forked: %{
      required: %{
        "room_id" => :id,
        "parent_room_id" => :id,
        "through_sequence" => :non_negative_integer,
        "inherited_message_ids" => :text_list
      },
      optional: %{}
    },
    participant_added: %{
      required: %{
        "room_id" => :id,
        "participant_id" => :id,
        "name" => :text,
        "responsibility" => :nullable_text,
        "provider" => :id,
        "model" => :nullable_text,
        "kind" => {:one_of, @participant_kinds}
      },
      optional: %{}
    },
    participant_configured: %{
      required: %{
        "room_id" => :id,
        "participant_id" => :id,
        "provider" => :id,
        "model" => :nullable_text
      },
      optional: %{}
    },
    participant_tier_configured: %{
      required: %{
        "room_id" => :id,
        "participant_id" => :id,
        "model_tier" => {:one_of, @model_tiers}
      },
      optional: %{}
    },
    message_posted: %{
      required: %{
        "message_id" => :id,
        "room_id" => :id,
        "turn_id" => :nullable_text,
        "body" => :text
      },
      optional: %{
        "author_name" => :text,
        "author_id" => :id,
        "author_kind" => {:one_of, ~w(user agent)}
      }
    },
    turn_queued: %{
      required: %{
        "turn_id" => :id,
        "room_id" => :id,
        "user_message_id" => :id,
        "mode" => {:one_of, @durable_modes},
        "context_through_sequence" => :non_negative_integer
      },
      optional: %{
        "participant_id" => :nullable_text,
        "input_kind" => {:one_of, @input_kinds},
        "source_invocation_id" => :id,
        "task" => :text,
        "detached" => :boolean
      }
    },
    turn_started: %{required: @turn_session_wire_identity, optional: %{"detached" => :boolean}},
    assistant_message_opened: %{
      required: %{
        "invocation_id" => :id,
        "message_id" => :id,
        "turn_id" => :id,
        "room_id" => :id,
        "participant" => :participant,
        "stage" => :non_negative_integer,
        "label" => :text,
        "system_prompt" => :nullable_text
      },
      optional: %{
        "phase" => :nullable_text,
        "cycle" => :non_negative_integer,
        "logical_work_id" => :nullable_text,
        "dependencies" => :text_list,
        "attempt" => :positive_integer,
        "delegated_from_invocation_id" => :id,
        "project_instructions" => :text,
        "project_instruction_digest" => :nullable_text,
        "project_instruction_sources" => :text_list,
        "model_tier" => {:one_of, @model_tiers},
        "token_budget_tokens" => :positive_integer,
        "output_schema" => :nullable_wire_map,
        "workspace" => :text,
        "workspace_roots" => :text_list,
        "isolation" => :nullable_wire_map,
        "delegated_from_tool_run_id" => :id,
        "delegation_depth" => :non_negative_integer
      }
    },
    operator_question_asked: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "question_id" => :id,
          "tool_run_id" => :id,
          "question" => :text,
          "options" => :map_list
        }),
      optional: %{
        "recommended_id" => :nullable_text,
        "multi" => :boolean,
        "allow_other" => :boolean
      }
    },
    operator_question_answered: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "question_id" => :id,
          "tool_run_id" => :id,
          "selected_id" => :id,
          "selected_label" => :text
        }),
      optional: %{
        "selected_ids" => :text_list,
        "selected_labels" => :text_list,
        "other" => :nullable_text
      }
    },
    invocation_plan_updated: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{"plan" => :wire_map}),
      optional: %{}
    },
    invocation_started: %{
      required: Map.merge(@invocation_identity, @turn_session_wire_identity),
      optional: %{}
    },
    invocation_steering_requested: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "steering_id" => :id,
          "body" => :text
        }),
      optional: %{}
    },
    provider_frame_recorded: %{
      required: %{
        "invocation_id" => :id,
        "message_id" => :nullable_text,
        "frame_sequence" => :non_negative_integer,
        "kind" => {:one_of, @frame_kinds},
        "data" => :wire_map
      },
      optional: %{}
    },
    invocation_completed: %{
      required: Map.merge(@invocation_identity, @turn_session_wire_identity),
      optional: %{"metadata" => :wire_map}
    },
    invocation_failed: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity) |> Map.put("error", :failure),
      optional: %{}
    },
    invocation_cancelled: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity) |> Map.put("reason", :text),
      optional: %{}
    },
    turn_completed: %{
      required: Map.merge(@turn_session_wire_identity, %{"outcome" => {:one_of, @outcomes}}),
      optional: %{}
    },
    snapshot_recorded: %{required: %{"binary" => :snapshot_binary}, optional: %{}},
    squad_configured: %{
      required: %{
        "turn_id" => :id,
        "room_id" => :id,
        "seats" => :text_list,
        "rework_budget" => :positive_integer
      },
      optional: %{
        "release_authority" => {:one_of, @release_authorities},
        "workflow_version" => :text,
        "phase" => :text
      }
    },
    squad_stage_entered: %{
      required: Map.merge(@turn_session_wire_identity, %{"stage" => :non_negative_integer}),
      optional: %{"phase" => :text, "cycle" => :non_negative_integer}
    },
    squad_decision_recorded: %{
      required:
        Map.merge(@turn_session_wire_identity, %{
          "seat_id" => :id,
          "decision" => {:one_of, @gate_decisions}
        }),
      optional: %{
        "phase" => :text,
        "cycle" => :non_negative_integer,
        "target_phase" => :nullable_text,
        "reasons" => :text_list
      }
    },
    squad_artifact_recorded: %{
      required: Map.merge(@turn_session_wire_identity, %{"seat_id" => :id, "kind" => :text}),
      optional: %{
        "phase" => :text,
        "cycle" => :non_negative_integer,
        "invocation_id" => :nullable_text,
        "message_id" => :nullable_text,
        "summary" => :text,
        "blockers" => :text_list,
        "digest" => :text
      }
    },
    squad_retry_scheduled: %{
      required:
        Map.merge(@turn_session_wire_identity, %{"seat_id" => :id, "attempt" => :positive_integer}),
      optional: %{
        "kind" => {:one_of, @retry_kinds},
        "phase" => :text,
        "cycle" => :non_negative_integer,
        "target_stage" => :non_negative_integer,
        "target_phase" => :text,
        "reason" => :text
      }
    },
    squad_role_configured: %{
      required: %{
        "room_id" => :id,
        "role_id" => :id,
        "name" => :text,
        "perspective" => :nullable_text,
        "provider" => :id,
        "model" => :nullable_text
      },
      optional: %{}
    },
    squad_directive_added: %{
      required:
        Map.merge(@turn_session_wire_identity, %{
          "text" => :text,
          "phase" => :text,
          "cycle" => :non_negative_integer
        }),
      optional: %{}
    },
    gate_review_requested: @gate_contract,
    gate_resolved: @gate_contract,
    squad_budget_extended: %{
      required: Map.merge(@turn_session_wire_identity, %{"budget" => :positive_integer}),
      optional: %{}
    },
    tool_ask_requested: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "request_id" => :id,
          "tool" => :text,
          "arguments" => :wire_map,
          "workspace" => :text
        }),
      optional: %{}
    },
    tool_ask_resolved: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "request_id" => :id,
          "tool" => :text,
          "decision" => {:one_of, @tool_decisions}
        }),
      optional: %{}
    },
    provider_round_recorded: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "round_index" => :non_negative_integer,
          "text" => :text,
          "tool_calls" => :map_list,
          "usage" => :nullable_wire_map
        }),
      optional: %{"steering" => :map_list}
    },
    tool_run_requested: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "tool_run_id" => :id,
          "tool_call_id" => :id,
          "round_index" => :non_negative_integer,
          "tool" => :text,
          "arguments" => :wire_map,
          "workspace" => :text,
          "authorization" => {:one_of, @authorizations}
        }),
      optional: %{"workspace_roots" => :text_list}
    },
    tool_run_approval_resolved: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "tool_run_id" => :id,
          "tool" => :text,
          "decision" => {:one_of, @tool_decisions}
        }),
      optional: %{}
    },
    tool_run_started: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{"tool_run_id" => :id, "tool" => :text}),
      optional: %{}
    },
    tool_run_completed: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{"tool_run_id" => :id, "tool" => :text, "result" => :wire_map}),
      optional: %{}
    },
    tool_run_failed: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "tool_run_id" => :id,
          "tool" => :text,
          "error" => :wire_map,
          "result" => :wire_map
        }),
      optional: %{}
    },
    tool_run_interrupted: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{"tool_run_id" => :id, "tool" => :text, "reason" => :text}),
      optional: %{}
    },
    delegation_opened: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "tool_run_id" => :id,
          "child_invocation_id" => :id,
          "child_message_id" => :id,
          "delegation_depth" => :non_negative_integer
        }),
      optional: %{"suspend_parent" => :boolean}
    },
    delegation_merge_requested: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "parent_invocation_id" => :id,
          "tool_run_id" => :id,
          "diff" => :text,
          "workspace" => :text,
          "source_workspace" => :text
        }),
      optional: %{}
    },
    delegation_merge_resolved: %{
      required:
        Map.merge(@invocation_identity, @turn_session_wire_identity)
        |> Map.merge(%{
          "tool_run_id" => :id,
          "decision" => {:one_of, @merge_decisions}
        }),
      optional: %{}
    },
    peer_message_sent: %{
      required:
        Map.merge(@turn_session_wire_identity, %{
          "peer_message_id" => :id,
          "sender_invocation_id" => :id,
          "sender_name" => :text,
          "target_invocation_id" => :id,
          "body" => :text
        }),
      optional: %{}
    }
  }

  @doc "Returns the event schema version accepted by this module."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version
  @doc "Returns the canonical list of event type atoms."
  @spec types() :: [atom()]
  def types, do: Map.values(@type_lookup)

  @doc "Returns the payload contract for an event type, or nil if unknown."
  @spec contract(atom()) :: %{required: map(), optional: map()} | nil
  def contract(type), do: Map.get(@contract, type)

  @doc "Builds and validates an event for an assigned global sequence."
  @spec new(pos_integer(), type(), map(), keyword()) :: t()
  def new(sequence, type, data, metadata \\ []) when is_map(data) do
    data = JSON.normalize(data)

    event = %__MODULE__{
      id: Integer.to_string(sequence),
      sequence: sequence,
      schema_version: @schema_version,
      type: type,
      aggregate_type: Keyword.fetch!(metadata, :aggregate_type),
      aggregate_id: Keyword.fetch!(metadata, :aggregate_id),
      room_id: metadata[:room_id],
      correlation_id: metadata[:correlation_id],
      causation_id: metadata[:causation_id],
      data: data,
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    }

    validate!(event)
  end

  @doc """
  Validates entry tuples against their payload contracts without persisting.

  Append paths call this before opening a durable transaction so malformed
  batches are rejected with a tagged error instead of failing mid-write.
  """
  @spec validate_entries([{atom(), map(), keyword()}]) ::
          :ok | {:error, {:invalid_event, atom(), String.t()}}
  def validate_entries(entries) do
    Enum.reduce_while(entries, :ok, fn {type, data, _metadata}, :ok ->
      case validate_entry_data(type, data) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_event, type, reason}}}
      end
    end)
  end

  defp validate_entry_data(type, data) do
    validate_data(type, JSON.normalize(data))
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc "Validates an event's type, aggregate identity, sequence, and complete payload shape."
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = event) do
    unless event.type in @known_types,
      do: raise(ArgumentError, "unknown event type #{inspect(event.type)}")

    unless event.aggregate_type in [:room, :turn, :invocation, :system],
      do: raise(ArgumentError, "invalid aggregate type")

    unless nonempty_string?(event.aggregate_id), do: raise(ArgumentError, "invalid aggregate id")

    unless is_integer(event.sequence) and event.sequence > 0,
      do: raise(ArgumentError, "invalid event sequence")

    unless is_map(event.data), do: raise(ArgumentError, "invalid event data")

    case validate_data(event.type, event.data) do
      :ok -> event
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc "Validates the complete wire shape of an event payload."
  @spec validate_data(type(), map()) :: :ok | {:error, String.t()}
  def validate_data(type, data)

  def validate_data(type, data) when is_map(data) do
    case Map.fetch(@contract, type) do
      {:ok, contract} -> validate_contract(contract, type, data)
      :error -> {:error, "unknown event type #{inspect(type)}"}
    end
  end

  def validate_data(type, _data), do: {:error, "invalid #{type} event: data must be an object"}

  defp validate_contract(contract, type, data) do
    with :ok <- require_fields(contract.required, type, data),
         :ok <- check_declared_fields(Map.merge(contract.required, contract.optional), type, data) do
      cross_field_rules(type, data)
    end
  end

  defp require_fields(required, type, data) do
    missing =
      required
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(data, &1))
      |> Enum.sort()

    if missing == [] do
      :ok
    else
      {:error,
       "invalid #{type} event: missing field(s) #{Enum.map_join(missing, ", ", &inspect(&1))}"}
    end
  end

  # Keys outside the contract are tolerated: schema-v2 events written by older
  # releases may carry fields this schema version does not declare.
  defp check_declared_fields(fields, type, data) do
    data
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      case declared_field_error(fields, type, key, value) do
        nil -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Keys outside the contract are tolerated: schema-v2 events written by older
  # releases may carry fields this schema version does not declare.
  defp declared_field_error(fields, type, key, value) do
    case Map.fetch(fields, key) do
      {:ok, rule} ->
        case check_rule(rule, value) do
          :ok -> nil
          {:error, detail} -> {:error, "invalid #{type} event: field #{inspect(key)} #{detail}"}
        end

      :error ->
        nil
    end
  end

  # Sibling-dependent rules that single-field rules cannot express.
  defp cross_field_rules(:provider_frame_recorded, %{"kind" => "text_delta", "data" => data}) do
    if is_map(data) and is_binary(Map.get(data, "text")) do
      :ok
    else
      {:error,
       "invalid provider_frame_recorded event: text_delta frames require field \"text\" with a string"}
    end
  end

  defp cross_field_rules(:provider_frame_recorded, %{"kind" => "agent_note", "data" => data}) do
    if is_map(data) and is_binary(Map.get(data, "note")) and Map.get(data, "note") != "" do
      :ok
    else
      {:error,
       "invalid provider_frame_recorded event: agent_note frames require field \"note\" with a non-empty string"}
    end
  end

  defp cross_field_rules(:provider_frame_recorded, _data), do: :ok

  defp cross_field_rules(:squad_retry_scheduled, %{"kind" => "rework"} = data) do
    rework_fields_valid? =
      is_integer(data["target_stage"]) and data["target_stage"] >= 0 and
        is_binary(data["target_phase"]) and
        is_integer(data["cycle"]) and data["cycle"] >= 0

    if rework_fields_valid? do
      :ok
    else
      {:error,
       "invalid squad_retry_scheduled event: rework retries require integer \"target_stage\", string \"target_phase\", and integer \"cycle\""}
    end
  end

  defp cross_field_rules(:squad_retry_scheduled, _data), do: :ok
  defp cross_field_rules(_type, _data), do: :ok

  # -- Field rules -----------------------------------------------------------

  defp check_rule(:id, value) when is_binary(value) and value != "", do: :ok
  defp check_rule(:id, _value), do: {:error, "must be a non-empty string"}

  defp check_rule(:text, value) when is_binary(value), do: :ok
  defp check_rule(:text, _value), do: {:error, "must be a string"}

  defp check_rule(:nullable_text, nil), do: :ok
  defp check_rule(:nullable_text, value), do: check_rule(:text, value)

  defp check_rule(:wire_map, value) when is_map(value), do: :ok
  defp check_rule(:wire_map, _value), do: {:error, "must be an object"}

  defp check_rule(:nullable_wire_map, nil), do: :ok
  defp check_rule(:nullable_wire_map, value), do: check_rule(:wire_map, value)

  defp check_rule(:text_list, value) do
    if is_list(value) and Enum.all?(value, &is_binary/1),
      do: :ok,
      else: {:error, "must be a list of strings"}
  end

  defp check_rule(:map_list, value) do
    if is_list(value) and Enum.all?(value, &is_map/1),
      do: :ok,
      else: {:error, "must be a list of objects"}
  end

  defp check_rule(:non_negative_integer, value)
       when is_integer(value) and value >= 0,
       do: :ok

  defp check_rule(:non_negative_integer, _value),
    do: {:error, "must be a non-negative integer"}

  defp check_rule(:positive_integer, value) when is_integer(value) and value > 0, do: :ok
  defp check_rule(:positive_integer, _value), do: {:error, "must be a positive integer"}
  defp check_rule(:boolean, value) when is_boolean(value), do: :ok
  defp check_rule(:boolean, _value), do: {:error, "must be a boolean"}

  defp check_rule({:one_of, values}, value) do
    if value in values,
      do: :ok,
      else: {:error, "must be one of #{inspect(values)}"}
  end

  defp check_rule(:participant_list, value) do
    if is_list(value) and Enum.all?(value, &participant?/1),
      do: :ok,
      else: {:error, "must be a list of participant objects"}
  end

  defp check_rule(:participant, value) do
    if participant?(value), do: :ok, else: {:error, "must be a participant object"}
  end

  defp check_rule(:failure, value) do
    case Failure.from_wire(value) do
      {:ok, _failure} -> :ok
      {:error, :invalid_failure} -> {:error, "must be a failure object"}
    end
  end

  defp check_rule(:snapshot_binary, value) do
    if is_binary(value) and match?({_binary, _rest}, Base.decode64(value)),
      do: :ok,
      else: {:error, "must be a base64-encoded snapshot"}
  end

  defp participant?(%{"id" => id, "name" => name, "provider" => provider} = participant)
       when is_binary(id) and id != "" and is_binary(name) and is_binary(provider) do
    case Map.fetch(participant, "kind") do
      {:ok, kind} -> kind in @participant_kinds
      :error -> true
    end
  end

  defp participant?(_participant), do: false

  @doc "Encodes an event as JSON, raising when encoding fails."
  @spec encode!(t()) :: String.t()
  def encode!(event), do: Jason.encode!(event)

  @doc "Decodes and validates a JSON event, normalizing compatible schema-v2 event types."
  @spec decode!(String.t()) :: t()
  def decode!(line), do: line |> Jason.decode!() |> decode_value!()

  @doc "Converts a decoded JSON map into a validated canonical event."
  @spec decode_value!(map()) :: t()
  def decode_value!(value) when is_map(value) do
    if value["schema_version"] != @schema_version do
      raise ArgumentError,
            "unsupported ReyCode event schema #{inspect(value["schema_version"])}; expected #{@schema_version}"
    end

    value = normalize_schema_v2_event(value)

    event = %__MODULE__{
      id: value["id"],
      sequence: value["sequence"],
      schema_version: value["schema_version"],
      type: Map.fetch!(@type_lookup, value["type"]),
      aggregate_type: aggregate_type(value["aggregate_type"]),
      aggregate_id: value["aggregate_id"],
      room_id: value["room_id"],
      correlation_id: value["correlation_id"],
      causation_id: value["causation_id"],
      data: value["data"],
      recorded_at: value["recorded_at"]
    }

    validate!(event)
  end

  # These schema-v2 types were replaced by provider frames. Persisted events
  # retain their original wire shape and normalize at this compatibility seam.
  defp normalize_schema_v2_event(%{"type" => "message_delta_appended", "data" => data} = value) do
    frame_data = %{
      "invocation_id" => Map.fetch!(data, "invocation_id"),
      "message_id" => Map.fetch!(data, "message_id"),
      "frame_sequence" => Map.fetch!(data, "frame_sequence"),
      "kind" => "text_delta",
      "data" => %{"text" => Map.fetch!(data, "delta")}
    }

    %{value | "type" => "provider_frame_recorded", "data" => frame_data}
  end

  defp normalize_schema_v2_event(
         %{"type" => "invocation_session_recorded", "data" => data} = value
       ) do
    frame_data = %{
      "invocation_id" => Map.fetch!(data, "invocation_id"),
      "message_id" => nil,
      "frame_sequence" => Map.fetch!(data, "frame_sequence"),
      "kind" => "session_started",
      "data" => %{"session_id" => Map.fetch!(data, "session_id")}
    }

    %{value | "type" => "provider_frame_recorded", "data" => frame_data}
  end

  defp normalize_schema_v2_event(value), do: value

  defp aggregate_type("room"), do: :room
  defp aggregate_type("turn"), do: :turn
  defp aggregate_type("invocation"), do: :invocation
  defp aggregate_type("system"), do: :system

  defp nonempty_string?(value), do: is_binary(value) and value != ""
end

defimpl Jason.Encoder, for: ReyCode.Event do
  def encode(event, opts) do
    Jason.Encode.map(
      %{
        id: event.id,
        sequence: event.sequence,
        schema_version: event.schema_version,
        type: event.type,
        aggregate_type: event.aggregate_type,
        aggregate_id: event.aggregate_id,
        room_id: event.room_id,
        correlation_id: event.correlation_id,
        causation_id: event.causation_id,
        data: event.data,
        recorded_at: event.recorded_at
      },
      opts
    )
  end
end
