defmodule Gralkor.IngestedRepresentation do
  @moduledoc """
  The successful result of storing one piece of evidence through one Lens.

  Multiple Lens representations of the same submitted information share an
  `evidence_id`; each representation has its own `id` and retains the Lens
  identity needed by post-ingestion Reflections.
  """

  @enforce_keys [:id, :evidence_id, :lens, :content, :result]
  defstruct [:id, :evidence_id, :lens, :content, :result]

  @type t :: %__MODULE__{
          id: String.t(),
          evidence_id: String.t(),
          lens: String.t(),
          content: String.t(),
          result: :ok
        }

  @spec new(Gralkor.Ingest.t()) :: t()
  def new(%Gralkor.Ingest{} = request) do
    evidence_id = request.evidence_id || unique_id("evidence")

    %__MODULE__{
      id: unique_id("representation"),
      evidence_id: evidence_id,
      lens: request.lens,
      content: request.content,
      result: :ok
    }
  end

  defp unique_id(kind) do
    "#{kind}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
