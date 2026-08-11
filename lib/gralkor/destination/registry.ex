defmodule Gralkor.Destination.Registry do
  @moduledoc false

  alias Gralkor.Destination

  def configured! do
    Application.get_env(:jido_gralkor, :destinations, [])
    |> Enum.map(&resolve!/1)
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
