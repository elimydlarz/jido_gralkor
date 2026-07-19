defmodule Gralkor.Ingest do
  @moduledoc false

  @enforce_keys [:operator_id, :lens, :content, :source_description]
  defstruct [:operator_id, :lens, :content, :source_description]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: String.t(),
          content: String.t(),
          source_description: String.t()
        }
end
