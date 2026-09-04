defmodule JidoGralkor.Runtime do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       owner: Keyword.fetch!(opts, :owner),
       configuration: Keyword.fetch!(opts, :configuration)
     }}
  end
end
