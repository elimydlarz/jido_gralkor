defmodule Gralkor.Reflection do
  @moduledoc "A named trigger-driven synthesis process that delivers one artefact through declared outputs."

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
