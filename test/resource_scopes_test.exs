defmodule ReyCode.ResourceScopesTest do
  use ExUnit.Case, async: false
  alias ReyCode.{ResourceScopes, RuntimeConfig, ToolRegistry}
  alias ReyCode.Tool.Request

  @tag :tmp_dir
  test "identical process names are isolated by workspace and Session", %{tmp_dir: dir} do
    a = Path.join(dir, "a") |> Path.expand()
    b = Path.join(dir, "b") |> Path.expand()
    File.mkdir_p!(a)
    File.mkdir_p!(b)
    config = RuntimeConfig.fresh(workspace_roots: [a, b])

    requests =
      for {workspace, session} <- [{a, "one"}, {b, "two"}, {a, "three"}] do
        Request.new(
          tool: "process",
          workspace: workspace,
          session_id: session,
          arguments: %{
            "action" => "start",
            "name" => "server",
            "command" => ["sh", "-c", "pwd; read line"]
          }
        )
      end

    for request <- requests do
      assert {:ok, %{ok: true}} = ToolRegistry.dispatch(request, config)
      {:ok, hub} = ResourceScopes.fetch(request, ReyCode.ProcessHub)
      on_exit(fn -> DynamicSupervisor.terminate_child(ReyCode.ResourceSupervisor, hub) end)

      waiting = %{
        request
        | arguments: %{
            "action" => "wait",
            "name" => "server",
            "pattern" => request.workspace,
            "timeout_ms" => 1_000
          }
      }

      assert {:ok, %{ok: true}} = ToolRegistry.dispatch(waiting, config)
    end

    [first, second | _] = requests

    assert {:ok, %{ok: true}} =
             ToolRegistry.dispatch(
               %{first | arguments: %{"action" => "stop", "name" => "server"}},
               config
             )

    assert {:ok, %{ok: true, output: output}} =
             ToolRegistry.dispatch(
               %{second | arguments: %{"action" => "logs", "name" => "server"}},
               config
             )

    assert output =~ "running"

    for request <- requests do
      {:ok, hub} = ResourceScopes.fetch(request, ReyCode.ProcessHub)
      DynamicSupervisor.terminate_child(ReyCode.ResourceSupervisor, hub)
    end
  end

  @tag :tmp_dir
  test "idle hub capacity is reclaimed across historical sessions", %{tmp_dir: dir} do
    for index <- 1..130 do
      assert {:ok, pid} =
               Task.async(fn ->
                 ResourceScopes.fetch(
                   Request.new(tool: "eval", workspace: dir, session_id: "idle-#{index}"),
                   ReyCode.EvalHub
                 )
               end)
               |> Task.await(15_000)

      assert is_pid(pid)
    end
  end

  @tag :tmp_dir
  test "evaluation kernels with the same name do not share state across sessions", %{tmp_dir: dir} do
    config = RuntimeConfig.fresh(workspace_roots: [dir])

    a =
      Request.new(
        tool: "eval",
        workspace: dir,
        session_id: "kernel-a",
        arguments: %{"action" => "start", "name" => "python", "language" => "python"}
      )

    b = %{a | session_id: "kernel-b"}

    for request <- [a, b] do
      assert {:ok, %{ok: true}} = ToolRegistry.dispatch(request, config)
      {:ok, hub} = ResourceScopes.fetch(request, ReyCode.EvalHub)
      on_exit(fn -> DynamicSupervisor.terminate_child(ReyCode.ResourceSupervisor, hub) end)
    end

    for {request, value} <- [{a, 11}, {b, 22}] do
      assert {:ok, %{ok: true}} =
               ToolRegistry.dispatch(
                 %{
                   request
                   | arguments: %{
                       "action" => "run",
                       "name" => "python",
                       "code" => "counter = #{value}"
                     }
                 },
                 config
               )
    end

    assert {:ok, %{ok: true, output: output}} =
             ToolRegistry.dispatch(
               %{
                 a
                 | arguments: %{
                     "action" => "run",
                     "name" => "python",
                     "code" => "_result = counter"
                   }
               },
               config
             )

    assert Jason.decode!(output)["value"] == "11"
  end

  @tag :tmp_dir
  test "restart readiness fails closed while a scoped process is running", %{tmp_dir: dir} do
    config = RuntimeConfig.fresh(workspace_roots: [dir])

    request =
      Request.new(
        tool: "process",
        workspace: dir,
        session_id: "restart-check",
        arguments: %{
          "action" => "start",
          "name" => "server",
          "command" => ["sh", "-c", "read line"]
        }
      )

    assert {:ok, %{ok: true}} = ToolRegistry.dispatch(request, config)
    {:ok, hub} = ResourceScopes.fetch(request, ReyCode.ProcessHub)
    on_exit(fn -> DynamicSupervisor.terminate_child(ReyCode.ResourceSupervisor, hub) end)
    assert {:error, :resource_work_active} = ResourceScopes.idle()

    assert {:ok, %{ok: true}} =
             ToolRegistry.dispatch(
               %{request | arguments: %{"action" => "stop", "name" => "server"}},
               config
             )

    assert :ok = ResourceScopes.idle()
  end
end
