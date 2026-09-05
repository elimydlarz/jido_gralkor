Functional: generalisation-reflection (src: lib/gralkor/reflection/runner.ex, lib/gralkor/client.ex, lib/gralkor/search.ex, lib/gralkor/ingested_representation.ex, lib/gralkor/destination/storage/in_memory.ex; functional: test/functional/generalisation_reflection_functional_test.exs)

when the packaged generalisation Reflection inspects a completed ingestion
  then one default related-memory episode search completes before generalisation inference begins
  and the search query contains the content of every completed representation
  and the same search reads every accessible registered Destination
  and every related observation identifies its originating Lens
  and related-memory results distinguish prior generalisations from Lens-authored observations
  and inference receives every current representation separately from related observations and generalisations
  and inference is directed to revisit current and related observations together with prior generalisations
  and inference is directed to carry forward, combine, broaden, narrow, split, replace, or otherwise revise generalisations as observations warrant
  and inference is directed to give a new generalisation level one and an evolved generalisation one level above its highest lineage snapshot
  and inference is directed to provide non-blank content for every current generalisation and lineage snapshot

when the packaged generalisation Reflection's default related-memory search returns no stored information
  then generalisation inference still inspects every current representation

if the packaged generalisation Reflection's default related-memory search fails
  then the Reflection fails before generalisation inference begins and identifies the search failure
  and the completed ingestion remains unchanged

when the packaged generalisation Reflection synthesises an evolved generalisation
  while its output satisfies the declared structured types
    then its model-produced values are preserved without comparison to related memory
  while the evolved generalisation replaces a prior generalisation
    then the replaced generalisation remains searchable as historical lineage

when the packaged generalisation Reflection completes
  then its artefact payload contains an array of generalisations
  and each returned generalisation contains exactly `content`, `level`, and `evolves_from`
  and the structured evolution is normalized directly into the artefact without a redundant synthesis inference
  and later evolution leaves every earlier returned lineage snapshot unchanged
