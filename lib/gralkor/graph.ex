defmodule Gralkor.Graph do
  @enforce_keys [:format, :data]
  defstruct [:format, :data]

  @type t :: %__MODULE__{
          format: atom(),
          data: term()
        }
end
