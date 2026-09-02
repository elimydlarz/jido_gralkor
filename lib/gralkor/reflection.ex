defmodule Gralkor.Reflection do
  @moduledoc "A named synthesis process that produces one artefact from an ordered Chain of Thought."

  alias Gralkor.Reflection.ChainOfThought

  @enforce_keys [:name, :chain_of_thought, :outputs]
  defstruct [:name, :chain_of_thought, :outputs]

  @type t :: %__MODULE__{
          name: String.t(),
          chain_of_thought: ChainOfThought.t(),
          outputs: [map()]
        }
end
