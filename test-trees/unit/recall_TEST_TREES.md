Unit: recall (src: lib/gralkor/recall.ex; unit: test/gralkor/recall_test.exs)

when no relevant facts are found
  then an empty graph result produces the no-memories body

when memory search returns facts
  then the memory block lists every returned fact verbatim and in order
  and every returned fact retains its available source wording

when a maximum result count is supplied
  then that count is forwarded to the main search

when no maximum result count is supplied
  then the main search receives the default count of ten

when recall receives a logical group id
  then it reaches the search boundary unchanged so GraphitiPool can encode it exactly once

if the agent name is missing or blank
  then an argument error is raised

when recall returns a memory block
  then the block is marked as untrusted and instructs the caller to search again for more detail

if the main graph search fails
  then its failure is returned without manufacturing a memory block

while a deadline budget governs recall
  if the budget expires before recall returns
    then a deadline-expired error is returned
    and a warning names the session
    and the warning names the configured budget
    where upstream is ordinary BEAM work
      then that work is stopped
  if recall finishes within the budget
    then the memory block is returned normally

when recall begins and completes
  then call metadata and result timing metrics are logged

where test mode is enabled
  then the raw query is logged
  and a returned-facts memory block is logged
  and an empty-result memory block is not logged

where test mode is disabled
  then neither the raw query nor memory block is logged
