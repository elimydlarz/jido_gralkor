defmodule Gralkor.Reflection.Storage.Graphiti do
  @moduledoc false
  @behaviour Gralkor.Reflection.Store

  alias Gralkor.Artefact
  alias Gralkor.GraphitiPool
  alias Gralkor.Reflection.Store

  @impl true
  def put(reflection, operator_id, %Artefact{} = artefact) do
    put_output(
      %{destination: reflection.destination, ontology: reflection.ontology},
      reflection.name,
      operator_id,
      artefact,
      fn group_id,
                                              content,
                                              source_description,
                                              ontology,
                                              opts ->
      GraphitiPool.add_episode(
        GraphitiPool,
        group_id,
        content,
        source_description,
        ontology,
        opts
      )
      end
    )
  end

  @doc false
  def put(reflection, operator_id, %Artefact{} = artefact, add_episode) do
    put_output(
      %{destination: reflection.destination, ontology: reflection.ontology},
      reflection.name,
      operator_id,
      artefact,
      add_episode
    )
  end

  def put_output(output, reflection_name, operator_id, %Artefact{} = artefact) do
    put_output(output, reflection_name, operator_id, artefact, fn group_id,
                                                                  content,
                                                                  source_description,
                                                                  ontology,
                                                                  opts ->
      GraphitiPool.add_episode(
        GraphitiPool,
        group_id,
        content,
        source_description,
        ontology,
        opts
      )
    end)
  end

  def put_output(output, reflection_name, operator_id, %Artefact{} = artefact, add_episode) do
    case add_episode.(
           Gralkor.Destination.graph_id(output.destination, operator_id),
           Jason.encode!(Map.from_struct(artefact)),
           "reflection:#{reflection_name}",
           output.ontology,
           uuid: artefact.id
         ) do
      {:error, {:episode_conflict, id}} -> {:error, {:artefact_conflict, id}}
      outcome -> outcome
    end
  end

  @impl true
  def get(reflection, operator_id, artefact_id) do
    get_output(
      %{destination: reflection.destination, ontology: reflection.ontology},
      reflection.name,
      operator_id,
      artefact_id
    )
  end


  def get_output(output, reflection_name, operator_id, artefact_id) do
    get_output(output, reflection_name, operator_id, artefact_id, &GraphitiPool.get_episode/2)
  end

  @doc false
  def get(reflection, operator_id, artefact_id, get_episode) do
    get_output(
      %{destination: reflection.destination, ontology: reflection.ontology},
      reflection.name,
      operator_id,
      artefact_id,
      get_episode
    )
  end

  def get_output(output, _reflection_name, operator_id, artefact_id, get_episode) do
    case get_episode.(Gralkor.Destination.graph_id(output.destination, operator_id), artefact_id) do
      {:ok, episode} ->
        case decode(episode) do
          [%Artefact{id: ^artefact_id} = artefact] ->
            if extraction_complete?(episode) do
              {:ok, artefact}
            else
              {:error, {:incomplete_artefact, artefact}}
            end

          [%Artefact{}] ->
            {:error, {:artefact_conflict, artefact_id}}

          [] ->
            {:error, {:invalid_artefact, artefact_id}}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def decode(%{content: content}), do: decode(content)
  def decode(%{"content" => content}), do: decode(content)

  def decode(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok,
       %{
         "id" => id,
         "payload" => payload
       } = decoded}
      when map_size(decoded) == 2 ->
        [%Artefact{id: id, payload: payload}]

      _ ->
        []
    end
  end

  def decode(_), do: []

  defp extraction_complete?(episode) do
    Map.get(episode, :extraction_complete, Map.get(episode, "extraction_complete", false)) == true
  end
end
