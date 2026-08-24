defmodule ReyCode.EventStore.SQLiteInternalsTest do
  @moduledoc """
  Direct coverage for the extracted SQLite internals: the pure checkpoint
  codec, the versioned migration planner, and backup/integrity helpers.
  """

  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias ReyCode.EventStore.SQLite.{Backup, Checkpoint, Migrations, Sql}
  alias ReyCode.{Failure, Hashing}

  alias ReyCode.Orchestration.{
    Invocation,
    Message,
    Participant,
    Projection,
    ProviderRound,
    Room,
    SquadRun,
    ToolRun,
    Turn
  }

  alias ReyCode.Orchestration.Squad.{GateRecommendation, GateResolution, GateReview, Seat}
  alias ReyCode.Provider.ToolCall

  describe "checkpoint codec" do
    test "round-trips typed records through the map-based checkpoint wire format" do
      participant = %Participant{
        id: "builder",
        name: "Builder",
        perspective: "implementation",
        provider: :simulator
      }

      seat = %Seat{
        id: "analyst",
        role_id: "analyst",
        name: "Analyst",
        perspective: "analysis",
        provider: :simulator
      }

      failure = Failure.new(:timeout, "timed out", true)
      recommendation = %GateRecommendation{decision: "approve"}
      review = %GateReview{id: "review-1", phase: "release_gate", recommendation: recommendation}

      resolution = %GateResolution{
        review_id: "review-1",
        resolver_id: "human_owner",
        authority: :owner,
        decision: "approve",
        phase: "release_gate"
      }

      squad = %SquadRun{
        room_id: "room-1",
        workflow_version: "squad-v3",
        phase_index: 14,
        phase: "release_gate",
        rework_budget: 3,
        role_ids: ["analyst"],
        reviews: [review],
        resolutions: [resolution],
        latest_resolution: resolution
      }

      projection = %Projection{
        sequence: 12,
        rooms: %{
          "room-1" => %Room{
            id: "room-1",
            slug: "alpha",
            participants: [participant],
            squad_seats: %{"analyst" => seat}
          }
        },
        room_order: ["room-1"],
        messages: %{
          "msg-1" => %Message{id: "msg-1", room_id: "room-1", body: "Hello", error: failure}
        },
        turns: %{
          "turn-1" => %Turn{
            id: "turn-1",
            room_id: "room-1",
            status: :terminal,
            outcome: :completed,
            squad: squad
          }
        },
        invocations: %{
          "inv-1" => %Invocation{
            id: "inv-1",
            participant: participant,
            phase_index: 0,
            usage: %{slug: :alpha, ratio: 0.5, span: {1, 2}},
            rounds: [
              %ProviderRound{
                index: 0,
                text: "read",
                tool_calls: [ToolCall.new("call-1", "read", %{"path" => "mix.exs"})]
              }
            ],
            tool_runs: %{"run-1" => %ToolRun{id: "run-1", status: :completed}},
            error: failure
          }
        }
      }

      payload = Jason.encode!(Checkpoint.encode_term(projection))
      checksum = Hashing.sha256_hex(payload)

      assert {:ok, decoded} =
               Checkpoint.decode(
                 payload,
                 Checkpoint.projection_version(),
                 12,
                 checksum,
                 1_000_000
               )

      refute Map.has_key?(decoded.rooms["room-1"], :__struct__)
      refute Map.has_key?(decoded.invocations["inv-1"].tool_runs["run-1"], :__struct__)
      assert Projection.from_map(decoded) == projection
    end

    test "rejects unsupported versions, size caps, and checksum mismatches" do
      payload = Jason.encode!(Checkpoint.encode_term(%{sequence: 3}))
      checksum = Hashing.sha256_hex(payload)

      assert {:error, {:unsupported_projection, 99}} =
               Checkpoint.decode(payload, 99, 3, checksum, 100)

      assert {:error, :checkpoint_too_large} =
               Checkpoint.decode(payload, Checkpoint.projection_version(), 3, checksum, 4)

      assert {:error, :checkpoint_checksum_mismatch} =
               Checkpoint.decode(payload, Checkpoint.projection_version(), 3, "bad", 100)

      assert {:error, :invalid_checkpoint} =
               Checkpoint.decode(42, Checkpoint.projection_version(), 3, checksum, 100)
    end

    test "rejects unknown atoms and shape or sequence mismatches" do
      bad_atom = Jason.encode!(["atom", "definitely_not_an_existing_atom"])

      assert {:error, :invalid_checkpoint} =
               Checkpoint.decode(
                 bad_atom,
                 Checkpoint.projection_version(),
                 3,
                 Hashing.sha256_hex(bad_atom),
                 100
               )

      valid_shape = %{
        sequence: 7,
        rooms: %{},
        room_order: [],
        messages: [],
        turns: %{},
        invocations: %{}
      }

      encoded = Jason.encode!(Checkpoint.encode_term(valid_shape))

      assert {:error, :invalid_checkpoint} =
               Checkpoint.decode(
                 encoded,
                 Checkpoint.projection_version(),
                 9,
                 Hashing.sha256_hex(encoded),
                 1_000_000
               )

      missing_keys = valid_shape |> Map.delete(:rooms) |> then(&Checkpoint.encode_term/1)
      encoded_missing = Jason.encode!(missing_keys)

      assert {:error, :invalid_checkpoint} =
               Checkpoint.decode(
                 encoded_missing,
                 Checkpoint.projection_version(),
                 7,
                 Hashing.sha256_hex(encoded_missing),
                 1_000_000
               )
    end
  end

  describe "migrations" do
    test "validates applied versions against this build's schema version" do
      assert :ok = Migrations.validate_versions([])
      assert :ok = Migrations.validate_versions([Migrations.schema_version()])

      future = Migrations.schema_version() + 1

      assert {:error, {:unsupported_schema_version, ^future, supported}} =
               Migrations.validate_versions([future])

      assert supported == Migrations.schema_version()
    end

    test "a failing migration step rolls back its version row" do
      connection = open_memory()

      :ok = Migrations.ensure_table(connection)

      assert_raise MatchError, fn ->
        Sql.transaction(connection, fn ->
          Sql.run!(
            connection,
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
            [Migrations.schema_version() + 99, Sql.now()]
          )

          # A step that violates the migration's own expectations.
          Sql.execute!(connection, "THIS IS NOT VALID SQL")
        end)
      end

      refute (Migrations.schema_version() + 99) in Migrations.applied_versions(connection)
      assert :ok = Sqlite3.close(connection)
    end
  end

  describe "backup and integrity" do
    test "writes an owner-only manifest bound to the database digest" do
      directory =
        Path.join([
          System.tmp_dir!(),
          "rey_code_backup_#{System.pid()}_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(directory)
      database = Path.join(directory, "backup.sqlite3")
      File.write!(database, "digestable")

      assert {:ok, manifest} = Backup.write_manifest(database, 5)

      assert manifest.sequence == 5
      assert manifest.database == database
      assert manifest.manifest == database <> ".manifest.json"
      assert manifest.schema_version == Migrations.schema_version()

      decoded = Jason.decode!(File.read!(manifest.manifest))
      assert decoded["sha256"] == manifest.sha256
      assert File.stat!(manifest.manifest).mode |> Bitwise.band(0o777) == 0o600

      File.rm_rf!(directory)
    end

    test "verifies paths read-only and rejects non-database files" do
      directory =
        Path.join([
          System.tmp_dir!(),
          "rey_code_verify_#{System.pid()}_#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(directory)
      not_a_database = Path.join(directory, "nope.sqlite3")
      File.write!(not_a_database, "garbage")

      assert {:error, _reason} = Backup.verify_path(not_a_database)
      File.rm_rf!(directory)
    end
  end

  defp open_memory do
    {:ok, connection} = Sqlite3.open(":memory:")
    connection
  end
end
