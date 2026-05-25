defmodule Gralkor.TestOntologies do
  @moduledoc """
  Ontology fixtures for tests that need a real `use Gralkor.Ontology` module
  (e.g. ex-config-ontology, the ex-client memory_add override contract).
  """

  defmodule Strict do
    @moduledoc false
    use Gralkor.Ontology, entities: :strict, relationships: :scoped

    entity User do
      field(:handle, :string, required: true)
    end

    entity Preference do
      field(:label, :string, required: true)
    end

    from User do
      prefers(Preference)
    end
  end

  defmodule NotAnOntology do
    @moduledoc false
  end
end
