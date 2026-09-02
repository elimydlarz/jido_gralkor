defmodule Gralkor.Reflection.Supervisor do
  @moduledoc false

  use Supervisor

  alias Gralkor.Reflection.Scheduler

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    scheduler_opts = Keyword.get(opts, :scheduler_opts, [])

    Supervisor.init([{Scheduler, scheduler_opts}], strategy: :one_for_one)
  end
end
