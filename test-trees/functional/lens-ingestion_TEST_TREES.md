Functional: lens-ingestion (src: lib/gralkor/lens/ingestion.ex, lib/gralkor/lens/ingestion/store.ex, lib/gralkor/lens/storage.ex; functional: test/functional/lens_ingestion_functional_test.exs)

when information is submitted through a registered Lens
  then the Lens's ingestion process receives the original information and a store bound to that Lens
  and the process may submit no episodes, one episode, or multiple episodes
  and every submitted episode is saved to the selected Lens's Destination
  and every submitted episode is extracted through the selected Lens's ontology
  and every directly submitted episode retains the selected Lens identity as source provenance

where information is submitted directly without a mounted plugin or conversational turn
  then the selected Lens's ingestion process runs without requiring an agent response or capture flush
  and the caller observes whether ingestion succeeded or failed

if ingestion selects an invalid Lens
  then ingestion fails before an ingestion process runs or memory is stored

if episode ingestion selects a replaceable Lens
  then ingestion fails with an error identifying that the Lens accepts only whole-graph replacement
  and no existing graph content is removed or inserted

if the selected Lens's ingestion process fails
  then ingestion returns that failure to the caller
  and no fallback write bypasses the selected process
