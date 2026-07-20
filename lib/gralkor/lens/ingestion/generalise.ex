defmodule Gralkor.Lens.Ingestion.Generalise do
  @behaviour Gralkor.Lens.Ingestion

  alias Gralkor.Client.Native
  alias Gralkor.Lens.Store

  @default_min_confidence 0.3

  @impl true
  def ingest(request, store) do
    hypothesise_fn =
      Application.get_env(
        :jido_gralkor,
        :generalise_hypothesise_fn,
        Native.generalise_hypothesise_callback()
      )

    min_confidence =
      Application.get_env(:jido_gralkor, :generalise_min_confidence, @default_min_confidence)

    with {:ok, candidates} <- hypothesise_fn.(prompt(request.content)) do
      candidates
      |> Enum.filter(&(Map.get(&1, :confidence, 0) >= min_confidence))
      |> Enum.reduce_while(:ok, fn candidate, :ok ->
        case Store.add(store, Map.fetch!(candidate, :content), request.source_description) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp prompt(transcript) do
    """
    Review the following conversation transcript and distil durable, evidence-backed generalisations that capture meaningful patterns, preferences, decisions, or recurring behaviours.

    Each generalisation must be supported by the transcript, useful beyond this conversation, and accompanied by a confidence score from 0.0 to 1.0.

    Transcript:
    #{transcript}
    """
  end
end
