Functional: ingested-information-provenance (src: lib/gralkor/ingest.ex, lib/gralkor/client.ex, lib/gralkor/client/native.ex, lib/gralkor/application.ex, lib/gralkor/search.ex, lib/gralkor/lens/store.ex, lib/gralkor/lens/storage/graphiti.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/destination/storage/in_memory.ex, lib/gralkor/graphiti_pool.ex; functional: test/functional/ingested_information_provenance_functional_test.exs)

when information is submitted through public ingestion with a supported source kind
  then its stored episode retains the declared source kind
  and its stored episode retains the reported source description
  and public episode search presents the originating Lens separately from episode content and source description
  and every returned fact identifies each originating episode by identifier, source kind, and source description
  and recall presents the extracted fact wording and its source attribution without rewriting either

where the source kind is conversation
  while the supplied content is speaker-attributed text
    then Graphiti receives a conversational-message episode containing that text

where the source kind is document
  while the supplied content is text
    then Graphiti receives a document-text episode containing that text

where the source kind is structured record
  while the supplied content is a JSON-compatible map or list
    then Graphiti receives a structured-data episode containing its JSON encoding

when information is submitted through public ingestion with a supported source kind
  then Graphiti's existing episode extraction is instructed to preserve source attribution and epistemic wording in extracted facts
  and Gralkor initiates no separate presentation-classification inference

when captured conversation turns are ingested automatically
  then Gralkor supplies conversation as their source kind
  and their rendered speaker-attributed transcript is submitted as a conversational-message episode

when information is added or captured directly without a selected Lens
  then its source kind and description remain unchanged without Lens or Reflection authorship
  and public episode and fact search include it without a Lens selector
  and storage-owned direct provenance prevents writer-like source descriptions from claiming Lens or Reflection authorship
  and writer-like source descriptions do not impose Reflection completion requirements

when public search reads historical operator-labelled episodes
  then their recorded operator Lens provenance remains visible without registering that Lens
  and a personal-chat Lens selector does not match those historical episodes

when public episode search encounters an incomplete Reflection episode
  then the incomplete Reflection episode does not contribute
  and completion filtering occurs before the per-Destination result limit

when public episode search encounters historical episodes without a named writer
  then the episodes remain available without invented Lens or Reflection authorship
  and historical fact sources retain their original source descriptions

if public ingestion omits or supplies an unsupported source kind
  then ingestion raises an argument error identifying the rejected source kind
  and no Lens ingestion process or Graphiti operation begins

if public ingestion supplies content whose shape does not correspond to its source kind
  then ingestion raises an argument error identifying the rejected source content
  and no Lens ingestion process or Graphiti operation begins

when public episode search reads completed Reflection output
  then the episode exposes the exact artefact identifier and structured payload with its Reflection source description
  if the stored Reflection body is not a valid artefact
    then search returns an explicit invalid artefact error

when public artefact search reads stored Reflection output
  then only records with a non-blank identifier and structured payload become canonical artefacts
