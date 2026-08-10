defmodule Gralkor.Reflection.Artefact do
  @moduledoc "One structured result produced by one completed Reflection run."

  @enforce_keys [:id, :reflection, :payload, :evidence_ids]
  defstruct [:id, :reflection, :payload, :evidence_ids]

  @type t :: %__MODULE__{
          id: String.t(),
          reflection: String.t(),
          payload: map(),
          evidence_ids: [String.t()]
        }

  def new(reflection, payload, evidence_ids) do
    id = "reflection-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    %__MODULE__{id: id, reflection: reflection, payload: payload, evidence_ids: evidence_ids}
  end
end
