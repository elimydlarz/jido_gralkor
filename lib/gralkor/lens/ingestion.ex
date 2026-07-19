defmodule Gralkor.Lens.Ingestion do
  @callback ingest(Gralkor.Ingest.t(), Gralkor.Lens.Store.t()) :: :ok | {:error, term()}
end
