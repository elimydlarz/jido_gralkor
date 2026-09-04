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

  defp ensure_started(owner) do
    case :global.whereis_name({__MODULE__, owner}) do
      :undefined ->
        {:ok, _state} = Jido.AgentServer.state(owner)
        :ok

      _pid ->
        :ok
    end
  end

  defp via(owner), do: {:global, {__MODULE__, owner}}
end
