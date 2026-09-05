Unit: memory-add-action (src: lib/jido_gralkor/actions/memory_add.ex; unit: test/jido_gralkor/actions/memory_add_test.exs)

when the memory add tool runs with content, a source kind, and a source description
  then it returns an acknowledgement immediately, without waiting on the write
  and the background write uses the graph named `operator/<operator id>`
  and the background write receives the content unchanged
  and the background write receives the source kind unchanged
  and the background write receives the source description unchanged
  where the tool context selects a Lens
    then the Lens ingestion receives the operator, content, source kind, and source description
    while the tool context identifies an owning AgentServer as the Gralkor runtime target
      then Lens ingestion uses that agent's current runtime configuration
    while the tool context has no Gralkor runtime target
      then Lens ingestion uses the application compatibility configuration
  if the background write fails
    then the failure is logged
    and the caller's acknowledgement is unaffected
