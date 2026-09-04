defmodule JidoGralkor.Runtime do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    GenServer.start_link(__MODULE__, opts, name: via(owner))
  end

  def snapshot(owner) do
    ensure_started(owner)
    GenServer.call(via(owner), :snapshot)
  end

  def replace(owner, configuration) do
    ensure_started(owner)
    GenServer.call(via(owner), {:replace, configuration})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       configuration: Keyword.fetch!(opts, :configuration)
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state.configuration, state}

  def handle_call({:replace, configuration}, _from, state) do
    case validate_configuration(configuration) do
      :ok -> {:reply, :ok, %{state | configuration: configuration}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_started(owner) do
    case :global.whereis_name({__MODULE__, owner}) do
      :undefined ->
        {:ok, _state} = Jido.AgentServer.state(owner)
        :ok

      _pid ->
        :ok
    end
  end

  defp validate_configuration(configuration) when is_map(configuration) do
    Enum.reduce_while([:destinations, :lenses, :reflections], :ok, fn collection, :ok ->
      case Map.fetch(configuration, collection) do
        {:ok, definitions} when is_list(definitions) ->
          {:cont, :ok}

        {:ok, invalid} ->
          {:halt, {:error, {:invalid_collection, collection, invalid}}}

        :error ->
          {:halt, {:error, {:missing_collection, collection}}}
      end
    end)
  end

  defp validate_configuration(configuration),
    do: {:error, {:invalid_configuration, configuration}}

  defp via(owner), do: {:global, {__MODULE__, owner}}
end
