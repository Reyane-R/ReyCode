defmodule ReyCode.Orchestration.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    agent_supervisor = Keyword.get(opts, :agent_supervisor, ReyCode.AgentSupervisor)
    engine_opts = Keyword.get(opts, :engine_opts, [])

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: agent_supervisor},
      {ReyCode.Orchestration.Engine,
       Keyword.put_new(engine_opts, :agent_supervisor, agent_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
