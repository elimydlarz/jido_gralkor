defmodule Gralkor.Lens.Ingestion.Store do
  alias Gralkor.Lens.Store

  @spec ingest(Gralkor.Ingest.t(), Store.t()) :: :ok | {:error, term()}
  def ingest(request, store) do
    Store.add(store, request.content, request.source_description)
  end
end
