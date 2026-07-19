defmodule Gralkor.Lens.Ingestion.Generalise do
  @behaviour Gralkor.Lens.Ingestion

  alias Gralkor.Client.Native
  alias Gralkor.Generalise
  alias Gralkor.Lens.Store

  @impl true
  def ingest(request, store) do
    hypothesise_fn =
      Application.get_env(
        :jido_gralkor,
        :generalise_hypothesise_fn,
        Native.generalise_hypothesise_callback()
      )

    evaluate_fn =
      Application.get_env(
        :jido_gralkor,
        :generalise_evaluate_fn,
        Native.generalise_evaluate_callback()
      )

    Generalise.generalise(request.operator_id, request.content,
      partition: store,
      ontology: store.lens.ontology,
      hypothesise_fn: hypothesise_fn,
      evaluate_fn: evaluate_fn,
      search_gen_fn: fn ^store, query, max_results ->
        Store.search(store, query, max_results)
      end,
      add_episode_fn: fn ^store, content, source, _ontology, opts ->
        Store.add(store, content, source, opts)
      end,
      remove_episode_fn: fn ^store, episode_id ->
        Store.remove(store, episode_id)
      end
    )
  end
end
