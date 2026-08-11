defmodule Gralkor.Destination.Registry do
  @moduledoc false

  alias Gralkor.Destination

  @packaged [
    %Destination{
      name: "operator",
      address: "operator/memory",
      ontology: Gralkor.DefaultOntology
    },
    %Destination{
      name: "experiential-learning",
      address: "operator/experiential-learning",
      ontology: Gralkor.Reflection.ERLOntology
    },
    %Destination{
      name: "generalisations",
      address: "global/generalisations",
      ontology: Gralkor.DefaultOntology
    }
  ]

  def configured! do
    case Application.get_env(:jido_gralkor, :destinations, []) do
      definitions when is_list(definitions) -> @packaged ++ Enum.map(definitions, &resolve!/1)
      invalid -> raise ArgumentError, "Destination registry must be a list, got #{inspect(invalid)}"
    end
  end

  def fetch!(name) when is_binary(name) do
    case Enum.find(configured!(), &(&1.name == name)) do
      nil -> raise ArgumentError, "unknown Destination #{inspect(name)}"
      destination -> destination
    end
  end

  defp resolve!(definition) do
    %Destination{
      name: Keyword.fetch!(definition, :name),
      address: Keyword.fetch!(definition, :address),
      ontology: Keyword.get(definition, :ontology, Gralkor.DefaultOntology)
    }
  end
end
