defmodule Gralkor.Reflection do
  @moduledoc "A named trigger-driven synthesis process that saves to a Destination."

  alias Gralkor.Reflection.ChainOfThought

  @enforce_keys [:name, :destination, :ontology, :chain_of_thought]
  defstruct [:name, :destination, :ontology, :chain_of_thought, outputs: [], triggers: []]

  @type t :: %__MODULE__{
          name: String.t(),
          destination: Gralkor.Destination.t(),
          ontology: module(),
          chain_of_thought: ChainOfThought.t(),
          outputs: [map()],
          triggers: list()
        }
end
