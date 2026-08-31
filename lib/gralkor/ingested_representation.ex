defmodule Gralkor.IngestedRepresentation do
  @moduledoc """
  The successful result of storing content through one Lens.

  Each representation has its own `id` and retains the Lens identity and
  content needed by post-ingestion Reflections.
  """

  @enforce_keys [:id, :lens, :content, :result]
  defstruct [:id, :lens, :content, :result]

  @type t :: %__MODULE__{
          id: String.t(),
          lens: String.t(),
          content: String.t(),
          result: :ok
        }

  @spec new(String.t(), String.t()) :: t()
  def new(lens, content) do
    %__MODULE__{
      id: unique_id("representation"),
      lens: lens,
      content: content,
      result: :ok
    }
  end

  defp unique_id(kind) do
    "#{kind}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
