defmodule Gralkor.Reflection do
  @moduledoc "A named post-ingestion process that saves to a Destination."

  alias Gralkor.Reflection.ChainOfThought

  @enforce_keys [:name, :destination, :chain_of_thought]
  defstruct [:name, :destination, :chain_of_thought]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          chain_of_thought: ChainOfThought.t()
        }
end
