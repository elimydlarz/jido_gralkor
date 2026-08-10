defmodule Gralkor.Reflection do
  @moduledoc "A named post-ingestion process with its own searchable destination."

  alias Gralkor.Reflection.ChainOfThought

  @enforce_keys [:name, :scope, :chain_of_thought]
  defstruct [:name, :scope, :chain_of_thought]

  @type t :: %__MODULE__{
          name: String.t(),
          scope: :operator | :global,
          chain_of_thought: ChainOfThought.t()
        }
end
