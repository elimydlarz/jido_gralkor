Functional: reflection-system (src: lib/gralkor/reflection.ex, lib/gralkor/reflection/registry.ex, lib/gralkor/reflection/chain_of_thought.ex, lib/gralkor/reflection/runner.ex, lib/gralkor/reflection/scheduler.ex, lib/gralkor/reflection/artefact.ex, lib/gralkor/reflection/store.ex; functional: test/functional/reflection_system_functional_test.exs)

when Reflection declarations are validated
  while every Reflection has a non-blank name
  and every Reflection name is unique
  and every Reflection references a repository YAML Chain of Thought
  and every referenced Chain of Thought contains one or more ordered steps
  and every step has a non-blank label and natural-language directions
  and every step declares one or more named structured outputs and their types
  and output names are unique across the Chain of Thought
  and every interpolation references an output from an earlier step
  and every Reflection destination is named by its Reflection and has operator or global scope
    then validation succeeds

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

  if an output name is declared by more than one step
    then validation fails identifying that Reflection, output name, and steps

  if an interpolation references an output not declared by an earlier step
    then validation fails identifying that Reflection, step, and interpolation

  if a Reflection has no destination scope
    then validation fails identifying that Reflection

  if a Reflection's destination scope is neither operator nor global
    then validation fails identifying that Reflection and destination scope

when an ingestion operation successfully stores information through one or more Lenses
  while Reflections are declared
    then every stored representation retains its evidence identifier and Lens identity
    and the ingestion caller receives success without waiting for Reflection
    and every declared Reflection is scheduled once for the completed ingestion operation
    and no Reflection begins before every intended Lens ingestion has completed

when a scheduled Reflection runs
  then its programmatic Chain of Thought runner loads the declared YAML
  and starts its first step for the operator and completed ingestion operation
  and makes every ingested representation available with its evidence identifier and Lens identity

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
  and the artefact is stored at the destination named by the Reflection
  and the artefact identifies its declaring Reflection
  and the artefact retains its supporting evidence identifiers

  where the declared destination is operator-scoped
    then the artefact is available only to the operator whose ingestion triggered the Reflection

  where the declared destination is global
    then the artefact is available through the shared global destination

when multiple declared Reflections process one completed ingestion operation
  then every Reflection runs independently
  and failure of one Reflection does not prevent another Reflection from completing

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

when memory is searched naming a Reflection
  then that Reflection's destination is searched
  and only artefacts produced by that Reflection are returned
  and every result identifies the named Reflection rather than a Lens
  and every result retains its supporting evidence identifiers

  where the search also identifies one artefact
    then only that artefact is returned from the named Reflection's destination

if memory is searched naming an unknown Reflection
  then the search fails identifying the unknown Reflection before any destination is searched
