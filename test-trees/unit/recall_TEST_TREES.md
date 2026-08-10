Unit: recall (src: lib/gralkor/recall.ex; unit: test/gralkor/recall_test.exs)

when a recall is requested
  then the query reaches interpretation even when the session conversation does not contain it

when no relevant facts are found
  then an empty graph result produces the no-memories body
  and interpretation selecting no facts produces the no-memories body

when interpretation selects relevant facts
  then the memory block lists every interpreted line verbatim and in order

when a non-blank session id is supplied
  then buffered turns are flat-walked in order with user and named-agent labels

when a nil session id is supplied
  then conversation context is empty and the turn buffer is not consulted

when a maximum result count is supplied
  then that count is forwarded to the main search

when no maximum result count is supplied
  then the main search receives the default count of ten

when an output token budget is supplied
  then that budget is forwarded to interpretation

when no output token budget is supplied
  then interpretation receives its default budget of two thousand

when a group id contains hyphens
  then every hyphen is replaced with an underscore before search

if the agent name is missing or blank
  then an argument error is raised

when recall returns a memory block
  then the block is marked as untrusted and instructs the caller to search again for more detail

if the main graph search fails
  then its failure is returned without manufacturing a memory block

if interpretation cannot parse its structured response
  then Gralkor.InterpretParseFailed carrying the invalid response reaches the recall caller

while a deadline budget governs recall
  if the budget expires before recall returns
    then a deadline-expired error is returned and a warning names the session and budget
    where upstream is ordinary BEAM work
      then that work is stopped
  if recall finishes within the budget
    then the memory block is returned normally

when recall begins and completes
  then call metadata and result timing metrics are logged
  where interpretation does not run
    then the interpretation duration is logged as zero

where test mode is enabled
  then the raw query is logged
  and a returned-facts memory block is logged
  and an empty-result memory block is not logged

where test mode is disabled
  then neither the raw query nor memory block is logged
