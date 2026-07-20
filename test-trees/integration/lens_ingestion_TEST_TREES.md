Integration: Lens ingestion (integration: none)

when information is submitted through a registered Lens
  then the Lens's ingestion process receives the original information and a store bound to that Lens
  and the process may submit no episodes, one episode, or multiple episodes
  and every submitted episode is added once with the selected Lens's ontology and memory destination
  and Graphiti owns extraction, duplicate resolution, temporal invalidation, persistence, and fact-to-episode provenance

where information is submitted directly without a mounted plugin or conversational turn
  then the selected Lens's ingestion process runs without requiring an agent response or capture flush
  and the caller observes whether ingestion succeeded or failed

if ingestion names an unknown or blank Lens
  then ingestion fails before an ingestion process or graph write is started

if the selected Lens's ingestion process fails
  then ingestion returns that failure to the caller
  and no fallback write bypasses the selected process
