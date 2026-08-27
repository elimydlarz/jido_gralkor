defmodule Gralkor.Lens.Ingestion do
  @moduledoc """
  Behaviour for consumer-defined Lens ingestion processes.

  An ingestion module receives the submitted `Gralkor.Ingest` request and a
  `Gralkor.Lens.Store` already bound to the request's operator, Lens ontology,
  and Destination. It may add no episodes, one episode, or several; returning
  an error returns that failure to the caller without an implicit fallback
  write.
  """

  @callback ingest(Gralkor.Ingest.t(), Gralkor.Lens.Store.t()) :: :ok | {:error, term()}
end
