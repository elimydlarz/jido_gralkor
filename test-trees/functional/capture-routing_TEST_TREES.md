Functional: capture-routing (src: lib/gralkor/capture.ex, lib/gralkor/client.ex, lib/gralkor/client/native.ex, lib/gralkor/capture_buffer.ex, lib/gralkor/application.ex; functional: test/functional/capture_routing_functional_test.exs)

when a caller submits a typed runtime-targeted capture request
  then a direct route writes once to the registered Destination resolved for its operator
  and a Lens route invokes each distinct selected Lens without an implicit direct write
  and a Lens keeps its declared Destination and ontology
  and each session binds its runtime owner, operator, agent, and user

when direct and Lens routes are selected across turns in one session
  then each selected route receives only its own turns in original order
  and distinct Lens definitions sharing a Destination remain separate batches

when runtime configuration changes or its owner terminates after capture is accepted
  then buffered routes retain their captured Destination, ontology, and ingestion definitions

when an asynchronous flush is requested
  then it schedules work and consumes the buffered entry before completion
  and shutdown waits for active and buffered capture work

when a caller awaits capture flush completion
  then successful completion consumes the buffered entry
  and terminal failure consumes the buffered entry
  and an await timeout preserves the buffered entry for another attempt

when one selected capture route fails
  then remaining selected routes are still attempted
  and the overall flush returns failure

when a capture route renders an empty transcript
  then no write or Lens ingestion runs

if a capture request has an invalid identity, canonical message, route, Destination, or selected Lens
  then capture fails before buffering any turn

if a caller uses a retired positional capture adapter
  then an explicit migration error identifies the typed runtime-targeted capture request

if typed capture and compatibility buffer calls reuse one session
  then the second mode is rejected without changing accepted turns
