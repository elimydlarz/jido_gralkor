Functional: runtime-configuration (src: none; functional: none)

when a consumer starts a Jido agent with the Gralkor plugin
  then the plugin starts one Gralkor runtime under that agent
  and that runtime owns the agent's runtime configuration
  and that runtime supervises the agent's Reflection processing and output delivery
  and it installs package-owned structured definitions for the `operator` and `global` Destinations
  and it installs the package-owned `operator` Lens
  and it installs package-owned structured definitions for the generalisations and ERL Reflections
  and it installs the complete consumer configuration supplied when the agent started

when a consumer replaces one agent's runtime configuration with complete valid Destination, Lens, and Reflection collections
  then the complete consumer configuration becomes active as one snapshot for that agent
  and the packaged Destinations, Lens, and Reflections remain active
  and another agent's runtime configuration remains unchanged
  and the call returns only after the replacement is active

if a replacement is invalid
  then the call returns the validation failure
  and that agent's previously active snapshot remains unchanged

when a consuming agent is restarted under consumer supervision
  then the consumer starts the agent with its current complete durable configuration
  and the restarted plugin installs that configuration before accepting memory work

if the consumer supplies invalid durable configuration while starting an agent
  then the Gralkor plugin fails to start for that agent
  and no part of the invalid configuration becomes active

if the Gralkor plugin runtime terminates unexpectedly
  while its linked AgentServer runs under consumer supervision
    then its linked AgentServer terminates
    and the consumer supervisor starts a replacement AgentServer
    and the replacement agent receives the consumer's current durable configuration

when complete runtime configuration contains an appending Lens declaring `write: :append`, a Destination, an ingestion module, and an optional ontology
  then replacement accepts the Lens for ingestion
  and an omitted ontology selects `Gralkor.DefaultOntology`

when complete runtime configuration contains a replaceable Lens declaring `write: :replace_graph` and a Destination
  then replacement accepts the Lens for complete-graph replacement

if a Lens definition combines appending and replacement fields
  then replacement fails identifying the incompatible Lens definition

if an ontology declares a custom entity kind named `Entity`, `Episodic`, or `Community`
  then replacement fails identifying the entity kind reserved by Graphiti

when an ontology declares custom entity kinds distinct from `Entity`, `Episodic`, and `Community`
  then those entity kinds remain eligible for runtime configuration

when named ingestion begins
  then it retains the Lens definition active when ingestion began
  and later named ingestion uses any subsequently installed Lens definition

when a named Reflection submission is admitted
  then its background work retains the Reflection definition active at admission
  and later submission uses any subsequently installed Reflection definition

when a search begins
  then it retains the Destination definitions active when search began
  and later search uses any subsequently installed Destination definitions
