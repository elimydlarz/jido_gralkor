defmodule Gralkor.Reflection do
  @moduledoc "A named trigger-driven synthesis process that saves to a Destination."

  alias Gralkor.Reflection.ChainOfThought

  @enforce_keys [:name, :chain_of_thought, :outputs]
  defstruct [:name, :chain_of_thought, :outputs, triggers: []]

  @type t :: %__MODULE__{
          name: String.t(),
          chain_of_thought: ChainOfThought.t(),
          outputs: [map()],
          triggers: list()
        }
end
