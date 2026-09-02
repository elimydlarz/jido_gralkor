Functional: reflection-triggering (src: lib/gralkor/reflection.ex, lib/gralkor/reflection/registry.ex, lib/gralkor/client.ex, lib/gralkor/capture_buffer.ex; functional: none)

when Reflection trigger declarations are validated
  while every Reflection declares one or more triggers
  and every trigger is `:programmatic`, `{:lens_ingestion, :all}`, or `{:lens_ingestion, [lens_name]}`
  and every Lens list is non-empty
  and every named Lens is a registered appending Lens
    then validation succeeds

  if a Reflection declares no triggers
    then validation fails identifying that Reflection and its missing triggers

  if a Reflection declares a trigger other than `:programmatic` or `:lens_ingestion`
    then validation fails identifying that Reflection and unsupported trigger

  if a Lens-ingestion trigger contains an empty Lens list
    then validation fails identifying that Reflection and empty Lens selection

  if a Lens-ingestion trigger names an unknown Lens
    then validation fails identifying that Reflection and unknown Lens

  if a Lens-ingestion trigger names a Lens that does not support appending ingestion
    then validation fails identifying that Reflection and incompatible Lens

where the packaged default Reflections are used
  then ERL declares `{:lens_ingestion, :all}`
  and generalisation declares `{:lens_ingestion, :all}`

when an ingestion successfully stores one or more representations through its intended Lenses
  then the ingestion caller receives success without waiting for Reflection completion
  and no Lens-ingestion Reflection is admitted before every intended Lens ingestion succeeds

  while a Reflection declares `{:lens_ingestion, :all}`
    then that Reflection is admitted exactly once for the completed ingestion
    and the ingestion identifier becomes its `invocation_id`
    and every completed representation is supplied to that Reflection

  while a Reflection names one or more completed Lenses in a Lens-ingestion trigger
    then that Reflection is admitted exactly once for the completed ingestion
    and the ingestion identifier becomes its `invocation_id`
    and every completed representation is supplied to that Reflection
    and additional matching Lenses do not admit another invocation for that ingestion

  while none of a Reflection's named Lenses completed
    then that Reflection is not admitted

  while a Reflection declares only `:programmatic`
    then that Reflection is not admitted

if any intended Lens ingestion fails
  then no Lens-ingestion Reflection is admitted for that incomplete ingestion

when a consumer programmatically requests a named Reflection with a non-blank `operator_id` and replay-stable `invocation_id`
  while that Reflection declares `:programmatic`
    then the consumer receives successful admission without waiting for Reflection completion
    and only the named Reflection is admitted for that request
    and the request content is supplied to that Reflection
    and the consumer's host tools and tool context are supplied to that Reflection
    and repeated requests with the same `{operator_id, invocation_id, reflection_name}` do not create another logical completion

  if the named Reflection is unknown
    then the request fails identifying the unknown Reflection before durable work is admitted

  if the named Reflection does not declare `:programmatic`
    then the request fails identifying the disabled programmatic trigger before durable work is admitted

  if the `operator_id` or `invocation_id` is missing or blank
    then the request fails identifying the invalid identity before durable work is admitted

when an ingestion completes with no eligible Lens-ingestion Reflection
  then ingestion succeeds without admitting Reflection work

