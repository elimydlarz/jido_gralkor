defmodule Gralkor.Lens.Storage.Graphiti do
  @moduledoc false

  @behaviour Gralkor.Lens.Storage

  @impl true
  def add_episode(_store, _content, _source_description) do
    raise "NotImplemented: Lens storage through Graphiti"
  end
end
