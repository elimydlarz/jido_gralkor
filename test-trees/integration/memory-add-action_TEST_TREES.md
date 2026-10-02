Integration: memory-add-action (src: lib/jido_gralkor/actions/memory_add.ex; integration: test/jido_gralkor/actions/memory_add_test.exs)

when a model reads the memory add tool's description
  then it is told to store higher-level conclusions because conversations are captured automatically
  and the source kind is limited to conversation, document, or structured record

when the memory add tool runs with content, a source kind, and a source description
  then it returns an acknowledgement immediately, without waiting on the write
  where the tool context selects no Lens
    then the background write uses the graph named `personal/<operator id>`
    and the background write receives the content unchanged
    and the background write receives the source kind unchanged
    and the background write receives the source description unchanged
  where the tool context selects a Lens
    then the Lens ingestion receives the operator, content, source kind, and source description
    while the tool context identifies an owning AgentServer as the Gralkor runtime target
      then Lens ingestion receives that owning AgentServer as its runtime target
    while the tool context has no Gralkor runtime target
      then Lens ingestion uses the untargeted application compatibility boundary
  if the background write or Lens ingestion fails
    then the failure is logged
    and the caller's acknowledgement is unaffected
