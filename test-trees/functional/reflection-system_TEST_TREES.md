Functional: reflection-system (src: lib/jido_gralkor/plugin.ex, lib/jido_gralkor/runtime.ex, lib/gralkor/reflection.ex, lib/gralkor/reflection/erl_ontology.ex, lib/gralkor/artefact.ex, lib/gralkor/reflection/chain_of_thought.ex, lib/gralkor/reflection/runner.ex, lib/gralkor/destination/storage/in_memory.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/client.ex, lib/gralkor/search.ex, lib/gralkor/ingested_representation.ex; functional: test/functional/reflection_system_functional_test.exs)

when an agent runtime validates Reflection declarations
  while every Reflection has a non-blank name
  and every Reflection name is unique
  and every Reflection contains one structured Chain of Thought
  and every Chain of Thought contains one or more ordered steps
  and every step has a non-blank label and natural-language directions
  and every step declares one or more named structured outputs and their types
  and output names are unique across the Chain of Thought
  and every interpolation references an output from an earlier step
  and every Reflection declares an `outputs` list
  and exactly one output has kind `:destination`
  and every Destination output references a registered Destination by name
  and every Destination output declares a valid extraction ontology
    then validation succeeds

  if the configured Reflection collection is not a list
    then validation fails identifying the configured value

  if a Reflection name is blank
    then validation fails identifying the blank name

  if a Reflection name contains the reserved provenance delimiter ` [lens: `
    then validation fails identifying the Reflection and reserved provenance syntax

  if Reflection names are duplicated
    then validation fails identifying the duplicate name

  if a Reflection has no Chain of Thought
    then validation fails identifying that Reflection

  if a Reflection's Chain of Thought is not structured configuration
    then validation fails identifying that Reflection and configured value

  if a Chain of Thought has no steps
    then validation fails identifying that Reflection and Chain of Thought

  if a Chain of Thought step has no non-blank label
    then validation fails identifying that Reflection and step

  if a Chain of Thought step has no natural-language directions
    then validation fails identifying that Reflection and step

  if a Chain of Thought step has no structured-output declaration
    then validation fails identifying that Reflection and step

  if a Chain of Thought step is not a map
    then validation fails identifying that Reflection and step

  if a Chain of Thought step declares an unsupported structured-output type
    then validation fails identifying that Reflection, step, and type

  if an output name is declared by more than one step
    then validation fails identifying that Reflection, output name, and steps

  if an interpolation references an output not declared by an earlier step
    then validation fails identifying that Reflection, step, and interpolation

  if a Reflection's `outputs` value is not a list
    then validation fails identifying that Reflection and outputs value

  if a Reflection declares no Destination output
    then validation fails identifying that Reflection and missing Destination output

  if a Reflection declares more than one Destination output
    then validation fails identifying that Reflection and duplicate Destination output kind

  if a Reflection declares an unsupported output kind
    then validation fails identifying that Reflection and output kind

  if a Destination output has no Destination name
    then validation fails identifying that Reflection and missing Destination

  if a Destination output references an unknown Destination
    then validation fails identifying that Reflection and Destination

  if a Destination output declares an invalid ontology
    then validation fails identifying that Reflection and ontology

when an agent's Gralkor runtime installs its package-owned Reflection definitions
  then ERL declares one Destination output referencing the packaged `operator` Destination
  and ERL's Destination output carries jido_gralkor's built-in experiential-learning ontology
  and generalisation declares one Destination output referencing the packaged `global` Destination

where an application-defined Destination output omits its ontology
  then the output selects generic extraction for a runtime-delivered artefact

where an application-defined Destination output declares an application ontology
  then the output selects that ontology for a runtime-delivered artefact

when a consumer stores the default ERL Reflection's artefact through its Destination output
  then extraction receives the built-in `Learning` entity type from that output's ontology
  and the `Learning` extraction contract declares optional problem kind, approach, success, and reusable lesson fields
  and the Runner-returned Learning payload contains exactly its problem kind, approach, success, and reusable lesson

when a consumer Reflection is installed in an agent's runtime configuration
  then its inline steps become the Reflection's Chain of Thought

when the package-owned generalisation Reflection is installed
  then it retains related-memory search and normalized generalisation artefacts

when a Reflection Runner is invoked
  then its ordered Chain of Thought runner starts its first step for the supplied operator and invocation
  and makes the consumer-supplied invocation context available to every step
  where the invocation supplies ingested representations
    then every representation is available with its identifier, Lens identity, content, and storage result

when a Chain of Thought step begins
  then built-in inference receives that step's interpolated natural-language directions
  and receives that step's declared structured-output contract
  and receives the complete tool set available to the host agent
  and the current step is the only step exposed to inference
  and built-in inference tool context uses the invocation's operator identity while retaining every other supplied context value

  where the directions reference outputs from earlier steps
    then every referenced value is interpolated from the Chain of Thought's shared output space

  where inference directs a tool call
    then the requested tool is called with the model-produced arguments
    and the tool result is returned to inference within the same step
    and inference continues within that step with access to the result and every configured tool

  where inference directs further tool calls
    then each requested call and result continues the same step in sequence

when inference returns a structured output for the current step
  while its keys and values satisfy that step's declared output contract
    then the output is added to the Chain of Thought's shared output space
    and the next step begins with those outputs available for interpolation

  if a declared output key is missing
    then the Reflection fails identifying its name, current step, and missing key

  if an undeclared output key is returned
    then the Reflection fails identifying its name, current step, and unexpected key

  if an output value does not satisfy its declared type
    then the Reflection fails identifying its name, current step, and type mismatch

when the final Chain of Thought step returns valid structured output
  then that structured output becomes one `%Gralkor.Artefact{}`
  and the artefact contains exactly its stable identifier and structured payload
  and the artefact carries no producer identity
  and the caller receives that artefact
  and the Runner does not deliver the declared Destination output

when a consumer triggers a named Reflection with an invocation callback
  then submission returns its invocation identifier without waiting for the Reflection to finish

if a consumer triggers a Reflection without a valid invocation callback
  then submission fails before the Reflection is admitted

if a consumer triggers a Reflection without a valid invocation identifier or operator identifier
  then submission fails before the Reflection is admitted

when an admitted Reflection completes successfully
  then its produced artefact is delivered to its Destination
  and the submitting consumer's callback eventually receives the same invocation identifier
  and that callback receives the produced artefact and successful delivery outcome

when independently submitted Reflection invocations are running
  then each invocation progresses without waiting for another invocation

if Reflection production fails
  then no Destination output is attempted
  and the invocation callback eventually receives the production failure

when a consumer-owned scheduled job triggers a Reflection
  then the scheduled job does not wait for the Reflection to finish
  and its invocation callback eventually receives the same completion or failure outcome as any other consumer trigger

if a Reflection's Chain of Thought completes without a valid final structured output
  then the Reflection fails identifying its name and missing artefact

if a Reflection's Chain of Thought fails
  then the Reflection failure identifies its name and reason

when a Destination is searched for artefacts
  then that Destination is searched
  and relevant artefacts written through any Destination output using that Destination are returned
  and every artefact contains exactly its stable identifier and structured payload

  where the search also identifies one artefact
    then only that artefact is returned from the selected Destination

if the retired `:reflection_storage` setting is configured
  then application startup fails identifying Destination outputs as the artefact memory boundary
