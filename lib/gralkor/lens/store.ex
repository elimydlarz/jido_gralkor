defmodule Gralkor.Lens.Store do
  @moduledoc false

  alias Gralkor.Lens

  @enforce_keys [:operator_id, :lens]
  defstruct [:operator_id, :lens]

  @type t :: %__MODULE__{
          operator_id: String.t(),
          lens: Lens.t()
        }

  @spec add(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def add(%__MODULE__{} = store, content, source_description) do
    storage().add_episode(store, content, source_description)
  end

  @spec storage() :: module()
  defp storage do
    Application.get_env(
      :jido_gralkor,
      :lens_storage,
      Gralkor.Lens.Storage.Graphiti
    )
  end
end
