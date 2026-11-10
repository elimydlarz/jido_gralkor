Unit: reflection-runner (src: lib/gralkor/reflection/runner.ex; unit: test/gralkor/reflection/runner_test.exs)

when the Reflection Runner receives a valid Reflection and invocation
  then the first ordered Chain of Thought step begins
  and every step request carries the Reflection name, operator, invocation identifier, and invocation context
  and completed representations retain exactly their identifier, Lens, content, and storage result
  and the request carries the supplied tools and tool context
  and only the current step is exposed to inference
  where a model resolver is supplied without a consumer inference function
    then every step's built-in inference runs the model that resolver names
  where an observer is supplied
    then the observer is told each step's label as that step starts
    and every step's built-in inference tells the observer of its tool calls
    when a step's output satisfies its contract
      then the observer is told that step's label as it finishes
    if a step fails
      then the observer is told that step's label as it fails

where a step's directions reference earlier outputs
  then those values are interpolated from the shared output space

where inference returns wrapped tool calls
  then each call is executed with its model-produced arguments and the current tool context
  and each result is returned to inference within the same step
  and further calls continue that step in sequence
  if a requested tool is not among the supplied tools
    then the unknown tool name is returned to inference as that call's result

when inference returns wrapped structured output satisfying the current step's exact contract
  then that output is added to the shared output space
  and the next step begins with it available for interpolation

if inference omits a declared output
  while the step is not the final step
    then the Runner failure identifies the Reflection, step, and missing key
  while the step is the final step
    then the Runner failure identifies the Reflection and missing artefact

if inference returns an undeclared output
  then the Runner failure identifies the Reflection, step, and unexpected key

if inference returns a value of the wrong declared type
  then the Runner failure identifies the Reflection, step, key, and type

when the final step returns valid wrapped structured output
  then the Runner returns one producer-independent artefact
  and its identifier is derived from the operator, invocation, and Reflection identity
  and its payload contains exactly the final step's outputs
  and the Runner performs no Destination delivery

if inference fails or returns an invalid response
  then the Runner failure identifies the Reflection, current step, and reason

when built-in inference is invoked for a step
  then it runs through Jido's standalone ReAct runtime with the directions, exact output contract, and representations
  and the representations and output contract remain JSON
  and it supplies the host tools and a tool context whose operator identity comes from the invocation while every other supplied field remains unchanged
  and a final JSON object is returned as wrapped structured output
  and each model call may produce up to 32,768 output tokens
  where a model resolver is supplied
    then it runs the model that resolver names
  where no model resolver is supplied
    then it runs Gralkor's configured LLM model
  if the provider fails or returns invalid JSON or a non-object JSON value
    then built-in inference returns the identified error
  if the ReAct runtime ends without a final answer
    then built-in inference returns its termination reason as an error
  if a model call's connection is closed, times out, or is refused before any HTTP status arrives
    then that model call is made again after 1 second, then 2, then 4, at most three more times
    and the model calls and tool calls that already finished in that step are not repeated
    if the connection fails on every attempt
      then built-in inference returns the connection error
  if a model call fails with an HTTP status
    then built-in inference returns the error without calling the model again
  where an observer is supplied
    when the ReAct runtime starts a tool call
      then the observer is told the call's identifier, tool name, and arguments
    when the ReAct runtime completes a tool call
      then the observer is told the call's identifier, tool name, duration, and whether it succeeded
    when the ReAct runtime emits any other event
      then the observer is told nothing
