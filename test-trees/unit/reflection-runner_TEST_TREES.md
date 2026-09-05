Unit: reflection-runner (src: lib/gralkor/reflection/runner.ex; unit: test/gralkor/reflection/runner_test.exs)

when the Reflection Runner receives a valid Reflection and invocation
  then the first ordered Chain of Thought step begins
  and every step request carries the Reflection, operator, invocation identifier, and invocation context
  and completed representations retain exactly their identifier, Lens, content, and storage result
  and the request carries the supplied tools and tool context
  and only the current step is exposed to inference

where a step's directions reference earlier outputs
  then those values are interpolated from the shared output space

where inference returns wrapped tool calls
  then each call is executed with its model-produced arguments and the current tool context
  and each result is returned to inference within the same step
  and further calls continue that step in sequence

when inference returns wrapped structured output satisfying the current step's exact contract
  then that output is added to the shared output space
  and the next step begins with it available for interpolation

if inference omits a declared output
  then the Runner failure identifies the Reflection, step, and missing key

if inference returns an undeclared output
  then the Runner failure identifies the Reflection, step, and unexpected key

if inference returns a value of the wrong declared type
  then the Runner failure identifies the Reflection, step, key, and type

when the final step returns valid wrapped structured output
  then the Runner returns one producer-independent artefact
  and its identifier is derived from the operator, invocation, and Reflection identity
  and its payload contains exactly the final step's outputs
  and the Runner performs no Destination delivery

if the Chain of Thought completes without valid final structured output
  then the Runner failure identifies the Reflection and missing artefact

if inference fails or returns an invalid response
  then the Runner failure identifies the Reflection, current step, and reason

when the packaged generalisation Reflection runs
  then one runtime-targeted related-memory episode search completes before inference
  and the search query contains every completed representation's content
  and the resulting stored information is available to every inference step
  if related-memory search fails
    then the Runner fails before inference and identifies the search failure

when another Reflection runs
  then no related-memory search is issued

when built-in inference is invoked for a step
  then it requests the configured model with the directions, exact output contract, representations, and stored information
  and it supplies the host tools and a tool context whose operator identity comes from the invocation while every other supplied field remains unchanged
  and a final JSON object is returned as wrapped structured output
  if the provider fails or returns invalid JSON or a non-object JSON value
    then built-in inference returns the identified error
