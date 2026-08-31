Functional: generalisation-reflection (src: lib/gralkor/reflection/runner.ex, lib/gralkor/client.ex, lib/gralkor/search.ex, lib/gralkor/ingested_representation.ex, priv/reflections/generalisations.yaml; functional: none)

when the packaged generalisation Reflection processes completed lensed representations
  then one related-memory episode search completes before generalisation inference begins
  and the search query contains the content of every completed representation
  and the same search reads the `operator` Destination, the `global` Destination, and every Destination referenced by the represented Lenses
  and stored generalisation artefacts returned from `global` are included alongside other related episodes
  and inference receives every current representation separately from the returned stored information

when the packaged generalisation Reflection's related-memory search returns no stored information
  then generalisation inference still processes every current representation

if the packaged generalisation Reflection's related-memory search fails
  then the Reflection fails before generalisation inference begins and identifies the search failure
  and the completed ingestion remains unchanged

when the packaged generalisation Reflection synthesises a generalisation
  while no returned generalisation influences the new generalisation
    then the new generalisation has level one
    and the new generalisation records no preceding generalisations
  while one or more returned generalisations influence the new generalisation
    then the new generalisation's level is one greater than the highest influencing level
    and the new generalisation records the content and level of every influencing generalisation
    but the new generalisation records no returned generalisation that did not influence it

when the packaged generalisation Reflection completes
  then its artefact payload contains an array of generalisations
  and each stored generalisation contains exactly its content, level, and preceding generalisations
  and each stored preceding generalisation contains exactly the content and level returned by the related-memory search
