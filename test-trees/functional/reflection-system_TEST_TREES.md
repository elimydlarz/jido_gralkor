Functional: reflection-system (src: lib/gralkor/reflection.ex, lib/gralkor/reflection/registry.ex, lib/gralkor/reflection/erl_ontology.ex, lib/gralkor/default_ontology.ex, lib/gralkor/reflection/chain_of_thought.ex, lib/gralkor/reflection/runner.ex, lib/gralkor/reflection/scheduler.ex, lib/gralkor/reflection/artefact.ex, lib/gralkor/reflection/store.ex, lib/gralkor/reflection/storage/in_memory.ex, lib/gralkor/reflection/storage/graphiti.ex, lib/gralkor/client.ex, lib/gralkor/search.ex, lib/gralkor/ingested_representation.ex, priv/reflections/erl.yaml, priv/reflections/generalisations.yaml; functional: test/functional/reflection_system_functional_test.exs)

when Reflection declarations are validated
  while every Reflection has a non-blank name
  and every Reflection name is unique
  and every Reflection references a repository YAML Chain of Thought
  and every referenced Chain of Thought contains one or more ordered steps
  and every step has a non-blank label and natural-language directions
  and every step declares one or more named structured outputs and their types
  and output names are unique across the Chain of Thought
  and every interpolation references an output from an earlier step
  and every Reflection references a registered Destination by name
    then validation succeeds

  if the configured Reflection registry is not a list
    then validation fails identifying the configured value

  if a Reflection name is blank
    then validation fails identifying the blank name

  if Reflection names are duplicated
    then validation fails identifying the duplicate name

  if a Reflection has no Chain of Thought
    then validation fails identifying that Reflection

  if a Reflection's Chain of Thought does not identify a repository YAML file
    then validation fails identifying that Reflection and file

  if a Reflection's Chain of Thought YAML cannot be loaded or parsed
    then validation fails identifying that Reflection, file, and parse failure

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

  if a Reflection has no Destination name
    then validation fails identifying that Reflection and missing Destination

  if a Reflection references an unknown Destination
    then validation fails identifying that Reflection and Destination

  if a Reflection declares an invalid ontology
    then validation fails identifying that Reflection and ontology

where the packaged default Reflections are used
  then ERL references the packaged `operator` Destination
  and ERL carries jido_gralkor's built-in experiential-learning ontology
  and generalisation references the packaged `global` Destination

where an application-defined Reflection omits its ontology
  then its final artefact receives generic extraction

where an application-defined Reflection declares an application ontology
  then its final artefact is extracted through that Reflection's ontology

when the default ERL Reflection stores its final artefact
  then extraction receives the built-in `Learning` entity type from ERL's ontology
  and the `Learning` extraction contract declares optional problem kind, approach, success, and reusable lesson fields
  and the stored Learning payload contains exactly its problem kind, approach, success, and reusable lesson

when an ingestion operation successfully stores information through one or more Lenses
  while Reflections are declared
    then every stored representation retains its own identifier, Lens identity, content, and storage result
    and the ingestion caller receives success without waiting for Reflection
    and every declared Reflection begins one logical completion flow for the completed ingestion operation
    and no Reflection begins before every intended Lens ingestion has completed

when a configured Reflection is loaded
  then its declared YAML is loaded as the programmatic Chain of Thought

when a scheduled Reflection runs
  then its programmatic Chain of Thought runner starts its first step for the operator and completed ingestion operation
  and makes every ingested representation available with its identifier, Lens identity, content, and storage result

when a Chain of Thought step begins
  then built-in inference receives that step's interpolated natural-language directions
  and receives that step's declared structured-output contract
  and receives the complete tool set available to the host agent
  and the current step is the only step exposed to inference

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
  then that structured output becomes the Reflection's single artefact
  and the artefact is stored at the Destination referenced by the Reflection
  and the artefact identifies its declaring Reflection
  and the artefact consists of its stable identifier, declaring Reflection, and structured payload

  where the referenced Destination is `operator`
    then the artefact is available only to the operator whose ingestion triggered the Reflection

  where the referenced Destination is not `operator`
    then the artefact is available to every operator through that Destination's one graph

when multiple declared Reflections process one completed ingestion operation
  then every Reflection runs independently
  and retry or terminal failure of one Reflection does not prevent another Reflection from completing

if any intended Lens ingestion fails
  then no Reflection is scheduled for the incomplete ingestion operation

if a Reflection's Chain of Thought completes without a valid final structured output
  then the Reflection fails identifying its name and missing artefact
  and the successful ingestion result remains unchanged

if a Reflection's Chain of Thought fails
  then the Reflection failure identifies its name and reason
  and the successful ingestion result remains unchanged
  and every other declared Reflection remains eligible to complete

if storing a Reflection artefact at its destination fails
  then the Reflection failure identifies its name, destination, and reason
  and the successful ingestion result remains unchanged
  and every other declared Reflection remains eligible to complete

when a Destination is searched for artefacts
  then that Destination is searched
  and relevant artefacts produced by any Reflection using that Destination are returned
  and every result identifies its declaring Reflection
  and every result retains its structured payload

  where the search also identifies one artefact
    then only that artefact is returned from the selected Destination
