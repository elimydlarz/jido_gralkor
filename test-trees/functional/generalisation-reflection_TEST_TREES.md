Functional: generalisation-reflection (src: lib/gralkor/reflection/runner.ex, lib/gralkor/client.ex, lib/gralkor/search.ex, lib/gralkor/ingested_representation.ex, lib/gralkor/destination/storage/in_memory.ex, priv/reflections/generalisations.yaml; functional: test/functional/generalisation_reflection_functional_test.exs)

when the packaged generalisation Reflection inspects a completed ingestion
  then one default related-memory episode search completes before generalisation inference begins
  and the search query contains the content of every completed representation
  and the same search reads every accessible registered Destination
  and every related observation identifies its originating Lens
  and every related generalisation identifies its declaring Reflection
  and inference receives every current representation separately from related observations and generalisations
  and inference is directed to revisit current and related observations together with prior generalisations
  and inference is directed to carry forward, combine, broaden, narrow, split, replace, or otherwise revise generalisations as observations warrant

when the packaged generalisation Reflection's default related-memory search returns no stored information
  then generalisation inference still inspects every current representation

if the packaged generalisation Reflection's default related-memory search fails
  then the Reflection fails before generalisation inference begins and identifies the search failure
  and the completed ingestion remains unchanged

when the packaged generalisation Reflection synthesises an evolved generalisation
  while no returned prior generalisation influences the evolved generalisation
    then the evolved generalisation has evolution-depth level one
    and the evolved generalisation's `evolves_from` is empty
  while one or more returned prior generalisations influence the evolved generalisation
    then the evolved generalisation's evolution-depth level is one greater than the highest influencing level
    and `evolves_from` records the content and level of every influencing prior generalisation
    but `evolves_from` records no returned generalisation that did not influence the evolution
  while the evolved generalisation replaces a prior generalisation
    then the replaced generalisation remains searchable as historical lineage

when the packaged generalisation Reflection completes
  then its artefact payload contains an array of generalisations
  and each stored generalisation contains exactly `content`, `level`, and `evolves_from`
  and each stored `evolves_from` snapshot contains exactly the content and level returned by related-memory search
  and later evolution leaves every earlier stored lineage snapshot unchanged
