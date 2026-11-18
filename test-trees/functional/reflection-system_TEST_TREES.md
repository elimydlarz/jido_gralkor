Functional: reflection-system (src: lib/jido_gralkor/plugin.ex, lib/jido_gralkor/runtime.ex, lib/gralkor/reflection.ex, lib/gralkor/artefact.ex, lib/gralkor/reflection/chain_of_thought.ex, lib/gralkor/reflection/runner.ex, lib/gralkor/destination/storage/in_memory.ex, lib/gralkor/destination/storage/graphiti.ex, lib/gralkor/client.ex, lib/gralkor/search.ex, lib/gralkor/ingested_representation.ex, lib/gralkor/application.ex; functional: test/functional/reflection_system_functional_test.exs)

when an agent runtime validates Reflection declarations
  while all declarations satisfy their naming, Chain-of-Thought, and Destination-output requirements
    then validation succeeds

  if the configured Reflection collection is not a list
    then validation fails identifying the configured value

  if a Reflection name is blank
    then validation fails identifying the blank name

  if a Reflection name contains the reserved provenance delimiter ` [lens: `
    then validation fails identifying the Reflection and reserved provenance syntax

  if a Reflection name contains the reserved direct-writer delimiter
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

  if a Chain of Thought step declares an output name holding a brace
    then validation fails identifying that Reflection, step, and output name

  if an output name is declared by more than one step
    then validation fails identifying that Reflection, output name, and steps

  if an interpolation references an output not declared by an earlier step
    then validation fails identifying that Reflection, step, and interpolation
    and an interpolation is identified whatever characters other than braces it holds
    and double braces whose text reaches another brace before closing double braces are not an interpolation

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

where an application-defined Destination output omits its ontology
  then the output selects generic extraction for a runtime-delivered artefact

where an application-defined Destination output declares an application ontology
  then the output selects that ontology for a runtime-delivered artefact

when a consumer Reflection is installed in an agent's runtime configuration
  then its inline steps become the Reflection's Chain of Thought

when a Reflection Runner is invoked
  then its ordered Chain of Thought runner starts its first step for the supplied operator and invocation
  and makes the consumer-supplied invocation context available to every step
  where the invocation supplies ingested representations
    then every representation is available with its identifier, Lens identity, content, and storage result

  while the initial step prompt exceeds 100,000 characters
    then the configured model receives the complete directions, representations, and output contract
    and valid model output completes the Reflection without a local prompt-length rejection

  while an earlier step's output makes a later step prompt exceed 100,000 characters
    then the configured model receives the complete interpolated output in that later step
    and valid model output completes the remaining Chain of Thought

  where the model requests tools before returning the current step's structured output
    then the supplied tools execute with the invocation's operator identity and supplied tool context
    and subsequent model turns receive the preceding tool results within that step
    and the next step starts only after the current step returns valid structured output

  if the model request fails
    then the Reflection fails identifying its name, current step, and provider failure
    and no later step is invoked

  if the model returns invalid JSON or a non-object JSON value
    then the Reflection fails identifying its name, current step, and invalid structured output
    and no later step is invoked

  if the model and tool loop reaches its iteration limit without a final answer
    then the Reflection fails identifying its name, current step, and exhausted iteration limit
    and no partial artefact is returned
    and no later step is invoked

when a Chain of Thought step begins
  then built-in inference receives that step's interpolated natural-language directions
  and receives that step's declared structured-output contract
  and receives the complete tool set available to the host agent
  and the current step is the only step exposed to inference
  and built-in inference tool context uses the invocation's operator identity while retaining every other supplied context value

  where the Runner is given a model resolver
    then built-in inference runs the model that resolver names
  where the Runner is given no model resolver
    then built-in inference runs Gralkor's configured LLM model
  where the Runner is given a reasoning effort
    then built-in inference asks the model for that reasoning effort
  where the Runner is given no reasoning effort
    then built-in inference names no reasoning effort

  where the directions reference outputs from earlier steps
    then every referenced value is interpolated from the Chain of Thought's shared output space
    and an output whose name holds a space is interpolated too
    and a value that is not a string is interpolated as its JSON encoding
    and double braces inside an interpolated value are not interpolated again
    where text put before the validated directions holds an unclosed double brace
      then every referenced value is still interpolated
      and that text reaches inference as written
    where text added to the validated directions holds double braces naming no earlier output
      then those braces and their text reach inference as written

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
    while the step is not the final step
      then the Reflection fails identifying its name, current step, and missing key
    while the step is the final step
      then the Reflection fails identifying its name and missing artefact

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

if a Reflection's Chain of Thought fails
  then the Reflection failure identifies its name and reason

when a Destination holding Reflection artefacts is searched
  then that Destination is searched
  and relevant artefacts written through any Destination output using that Destination are returned among its episodes
  and every returned artefact contains exactly its stable identifier and structured payload

  where the caller identifies one artefact
    then that artefact is found among the Destination's episodes by its identifier
    and exact lookup by that identifier returns only that artefact

if the retired `:reflection_storage` setting is configured
  then application startup fails identifying Destination outputs as the artefact memory boundary

when a Reflection delivers to personal memory
  then its artefact is searchable only by the invocation identity
  and its artefact identifier remains derived from the unchanged operator and invocation identifiers

when the Runner runs one step on its own
  then built-in inference receives the step's declared output contract
  and built-in inference receives the supplied tools
  and built-in inference receives no Reflection name
  and built-in inference receives no representations
  when the model asks for a supplied tool
    then that tool executes with exactly the supplied tool context
  where a reference in the directions names a supplied value
    where the value is a string
      then built-in inference receives the directions with that reference replaced by the string
    where the value is not a string
      then built-in inference receives the directions with that reference replaced by the value's JSON encoding
    where the value holds a reference naming another supplied value
      then that inner reference reaches the model as written
  where a reference in the directions names no supplied value
    then that reference reaches the model as written
  where the directions hold an unclosed double brace ahead of a reference naming a supplied value
    then that reference is filled in from its value
    and the unclosed double brace reaches the model as written
  where the step is given a model
    then every model request of the step runs that model
  where the step is given no model
    then every model request of the step runs Gralkor's configured LLM model
  where the step is given a reasoning effort
    then every model request of the step asks for that reasoning effort
  where the step is given no reasoning effort
    then no model request of the step names a reasoning effort
  when the model returns structured output satisfying the step's declared output contract
    then the Runner returns exactly those outputs
    and the Runner returns no artefact
  if a declared output key is missing
    then the step fails identifying the missing key
  if an undeclared output key is returned
    then the step fails identifying the unexpected key
  if an output value does not satisfy its declared type
    then the step fails identifying the key and type
  if the model request fails
    then the step fails identifying the provider failure
  if the model returns invalid JSON or a non-object JSON value
    then the step fails identifying the invalid structured output
  if the model and tool loop reaches its iteration limit without a final answer
    then the step fails identifying the exhausted iteration limit
  if the step fails
    then its failure names no Reflection and no step

where the Runner runs a Reflection or one step on its own with an observer
  when built-in inference starts a model request
    then the observer is told the request's identifier
    when that model request finishes
      then the observer is told the request's identifier, its duration, and its token use
    if that model request fails
      then the observer is told the request's identifier, its duration, and that it failed
    if that model request gets no answer in the time allowed
      then the observer is told the request's identifier, its duration, and that it failed
  when built-in inference starts a tool call
    then the observer is told the call's identifier, tool name, and arguments
    when that tool call completes
      then the observer is told the call's identifier, tool name, duration, and whether it succeeded
      and the observer is told the call's result as the model receives it

where the Runner runs a Reflection or one step on its own with a time allowed for a tool call
  if a tool call runs longer than that time
    then that tool call fails
    and the model receives that failure within the same step

where the Runner runs a Reflection or one step on its own without being given a time allowed for a tool call
  if a tool call runs longer than the default time
    then that tool call fails
    and the model receives that failure within the same step

where the Runner runs a Reflection or one step on its own with a limit on rounds of tool use in a step
  if the model keeps asking for tools beyond that many rounds
    then the step fails identifying the exhausted iteration limit
    and the model receives no more requests in that step than that limit

where the Runner runs a Reflection or one step on its own without being given a limit on rounds of tool use in a step
  if the model keeps asking for tools beyond the default number of rounds
    then the step fails identifying the exhausted iteration limit
    and the model receives no more requests in that step than the default number

where the Runner runs a Reflection or one step on its own with a limit on tool calls at once
  when the model asks for more tool calls in one answer than that limit
    then no more than that limit of them run at the same time
    and as many of them as that limit run at the same time
    and the model receives every one of their results within the same step

where the Runner runs a Reflection or one step on its own without being given a limit on tool calls at once
  when the model asks for more tool calls in one answer than the default limit
    then no more than the default limit of them run at the same time
    and as many of them as the default limit run at the same time
    and the model receives every one of their results within the same step
