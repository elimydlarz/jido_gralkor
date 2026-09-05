Unit: jido-gralkor-runtime (src: lib/jido_gralkor/runtime.ex; unit: test/jido_gralkor/runtime_test.exs)

when a runtime starts for an owning AgentServer PID with valid complete configuration
  then one runtime owns that agent's active configuration
  and the packaged Destinations, operator Lens, and Reflections are available beside consumer definitions
  and admitted Reflection production and delivery run asynchronously under that runtime

when a consumer replaces complete valid configuration
  then every definition is validated and resolved before activation
  and the complete configuration becomes active as one snapshot
  and package-owned definitions remain active
  and another owner's runtime remains unchanged
  and replacement returns only after the new snapshot is active

if replacement configuration is invalid
  then replacement returns the validation error
  and the previously active snapshot remains unchanged

if runtime configuration is not a map
  then validation identifies the configured value

if runtime configuration contains an unknown top-level field
  then validation identifies every unknown field

if a required Destination, Lens, or Reflection collection is absent
  then validation identifies the missing collection

if a Destination, Lens, or Reflection collection is not a list
  then validation identifies the collection and configured value

if a definition is neither a map nor a keyword list
  then validation identifies its collection and configured value

if a definition contains unknown fields
  then validation identifies its collection, name, and unknown fields

if a Destination, Lens, or Reflection name is missing, blank, or duplicated
  then validation identifies the collection and invalid name

if a consumer definition uses a name reserved by a package-owned definition
  then validation identifies its collection and reserved name

if a Destination name uses the reserved `operator/` namespace or a Lens uses the retired `default` name
  then validation identifies the reserved or retired name

if a Lens or Reflection name contains the reserved provenance delimiter ` [lens: `
  then validation identifies the collection and name

if a Lens or Reflection references an unknown Destination
  then validation identifies the definition and Destination

when an appending Lens declares `write: :append`, a Destination, and a valid ingestion module
  then it resolves as an appending Lens
  and an omitted ontology resolves to `Gralkor.DefaultOntology`

if an appending Lens has a missing or invalid ingestion module or an invalid ontology
  then validation identifies the Lens and invalid field

if a map supplies an atom-keyed ontology value and a string-keyed ontology value
  then the atom-keyed value remains authoritative even when it is false

when a replaceable Lens declares `write: :replace_graph` and a Destination
  then it resolves as a replaceable Lens

if a replaceable Lens also declares ingestion or ontology fields
  then validation identifies the incompatible Lens definition

if a Lens declares any other write mode
  then validation identifies the Lens and write value

if a Reflection's outputs value is not a list or contains a malformed output
  then validation identifies the Reflection and invalid output

if a Reflection declares no Destination output or more than one Destination output
  then validation identifies the Reflection and output count failure

if a Reflection declares an unsupported output kind
  then validation identifies the Reflection and output kind

if a Reflection output has a missing or unknown Destination or invalid ontology
  then validation identifies the Reflection and invalid output field

if a Reflection's Chain of Thought is missing, unstructured, empty, or contains a malformed step
  then validation identifies the Reflection and Chain of Thought failure

if a Chain of Thought or one of its steps contains unknown fields
  then validation identifies the Reflection, step when applicable, and unknown fields

if a configured ontology declares `Entity`, `Episodic`, or `Community`
  then validation identifies the entity kind reserved by Graphiti

when a configured ontology declares another entity kind
  then it remains eligible for configuration

when search definitions are resolved from an active runtime
  while no Destination names are supplied
    then every accessible Destination and every selected Lens resolve from one snapshot
  while Destination and Lens names are supplied
    then those definitions resolve from one snapshot in first-selected order without duplicates
  and later replacement does not mutate the returned definitions
  if any selected name is unknown
    then resolution fails without returning a partial result

when a runtime-targeted call receives a live owning AgentServer PID
  then the runtime registered for that owner receives the call
  while runtime registration is not yet visible
    then target lookup synchronizes once with the owner before deciding availability

if a runtime target is not an owning AgentServer PID
  then target lookup raises an argument error identifying the invalid target

if no runtime is available after owner synchronization or the runtime call exits
  then target lookup raises an argument error identifying the unavailable runtime

when a valid named Reflection submission is admitted
  then callback, invocation identifier, operator identifier, and Reflection existence are validated before work starts
  and submission returns the invocation identifier without waiting for production
  and the work retains the Reflection definition active at admission
  and later submission uses a subsequently installed definition

if the callback is invalid, an invocation or operator identifier is missing or blank, or the Reflection is unknown
  then submission returns the identified failure before production starts

when Reflection production and Destination delivery succeed
  then the artefact is written once through the declared Destination output
  and the callback receives the invocation identifier, artefact, and delivered outcome

if Reflection production fails without a retryable server or non-retryable client status
  then no Destination output is attempted and the callback receives the production failure

if Reflection production reports a non-retryable client failure
  then it is not retried or delivered and the callback receives immediate production abandonment

if Reflection production reports a retryable server failure
  then production retries with exponential backoff
  while a retry succeeds before twenty-four hours
    then delivery proceeds and the callback receives the terminal outcome
  while no retry succeeds within twenty-four hours
    then production is abandoned without another attempt and the callback receives abandonment

if Destination delivery reports a non-retryable client failure
  then no retry or error artefact is written and the callback receives abandonment with the produced artefact

if Destination delivery reports a retryable server failure
  then delivery retries the same artefact with exponential backoff
  while a retry succeeds before twenty-four hours
    then the callback receives the delivered outcome
  while no retry succeeds within twenty-four hours
    then delivery is abandoned without another attempt and the callback receives the artefact and abandonment

when independently submitted Reflection invocations run
  then each invocation progresses without waiting for another invocation

when the owning runtime terminates during unfinished Reflection work
  then the unfinished work terminates with that runtime
  and its invocation callback is not invoked
