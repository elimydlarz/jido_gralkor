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

when information is added or captured through the implicit operator Lens
  then its trusted originating Lens is `operator`
  and public episode search can select it through the `operator` Lens
  and trusted trailing `operator` Lens provenance governs public writer attribution and completion handling despite writer-like source text

when public episode search encounters an incomplete Reflection episode
  then the incomplete Reflection episode does not contribute
  and completion filtering occurs before the per-Destination result limit

when public episode search encounters an episode without a trusted Lens suffix or Reflection prefix
  then the unprovenanced episode does not contribute
  and provenance filtering occurs before the per-Destination result limit

if public ingestion omits or supplies an unsupported source kind
  then ingestion raises an argument error identifying the rejected source kind
  and no Lens ingestion process or Graphiti operation begins

if public ingestion supplies content whose shape does not correspond to its source kind
  then ingestion raises an argument error identifying the rejected source content
  and no Lens ingestion process or Graphiti operation begins
