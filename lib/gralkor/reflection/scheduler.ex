defmodule Gralkor.Reflection.Scheduler do
  @moduledoc "Schedules independent Reflections once after a multi-Lens ingestion has completed."

  use GenServer

  alias Gralkor.Reflection.Runner
  alias Gralkor.Reflection.Store

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def schedule(reflections, ingestion, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:schedule, reflections, ingestion, opts})
  end

  @impl true
  def init(_opts), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:schedule, reflections, ingestion, opts}, _from, scheduled) do
    id = field(ingestion, :id)

    cond do
      not completed?(ingestion) -> {:reply, {:error, {:incomplete_ingestion, id}}, scheduled}
      MapSet.member?(scheduled, id) -> {:reply, {:ok, :already_scheduled}, scheduled}
      true ->
        Enum.each(reflections, &start_reflection(&1, ingestion, opts))
        {:reply, {:ok, :scheduled}, MapSet.put(scheduled, id)}
    end
  end

  defp start_reflection(reflection, ingestion, opts) do
    runner = Keyword.get(opts, :runner, &Runner.run/3)
    runner_opts = Keyword.get(opts, :runner_opts, [])
    store_opts = Keyword.get(opts, :store_opts, [])
    notify = Keyword.get(opts, :notify)

    Task.start(fn ->
      outcome =
        case runner.(reflection, ingestion, runner_opts) do
          {:ok, artefact} ->
            case Store.put(reflection, field(ingestion, :operator_id), artefact, store_opts) do
              :ok -> {:ok, artefact}
              {:error, reason} -> {:error, %{reflection: reflection.name, destination: reflection.name, reason: reason}}
            end
          {:error, _} = error -> error
        end

      if is_pid(notify), do: send(notify, {:reflection_completed, reflection.name, outcome})
    end)
  end

  defp completed?(ingestion) do
    representations = field(ingestion, :representations) || []
    intended = field(ingestion, :intended_lenses) || Enum.map(representations, &field(&1, :lens))
    successful = Enum.filter(representations, &(field(&1, :result) in [nil, :ok]))
    successful_lenses = MapSet.new(successful, &field(&1, :lens))

    representations != [] and length(successful) == length(representations) and
      Enum.all?(intended, &MapSet.member?(successful_lenses, &1))
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
