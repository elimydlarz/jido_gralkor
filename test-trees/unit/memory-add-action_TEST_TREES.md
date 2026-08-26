Unit: memory-add-action (src: lib/jido_gralkor/actions/memory_add.ex; unit: test/jido_gralkor/actions/memory_add_test.exs)

when the memory add tool runs with content, a source kind, and a source description
  then it returns an acknowledgement immediately, without waiting on the write
  and the write is carried out in the background under the operator's sanitised group id, carrying the content, source kind, and source description as given
  where the tool context selects a Lens
    then the background write is routed to that Lens's ingestion for the operator, carrying the content, source kind, and source description
  if the background write fails
    then the failure is logged
    and the caller's acknowledgement is unaffected
