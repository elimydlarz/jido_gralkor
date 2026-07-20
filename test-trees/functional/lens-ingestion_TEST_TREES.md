Functional: lens-ingestion (functional: test/functional/lens_ingestion_functional_test.exs)

when information is submitted through a registered Lens
  then the Lens's ingestion process receives the original information and a store bound to that Lens
  and the process may submit no episodes, one episode, or multiple episodes
  and every submitted episode is governed by the selected Lens's ontology and scope

where information is submitted directly without a mounted plugin or conversational turn
  then the selected Lens's ingestion process runs without requiring an agent response or capture flush
  and the caller observes whether ingestion succeeded or failed

if ingestion selects an invalid Lens
  then ingestion fails before an ingestion process runs or memory is stored

if the selected Lens's ingestion process fails
  then ingestion returns that failure to the caller
  and no fallback write bypasses the selected process
