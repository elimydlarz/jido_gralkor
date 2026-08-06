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

while a deadline budget governs recall
  if the budget expires before recall returns
    then a deadline-expired error is returned and a warning names the session and budget
    and ordinary BEAM work owned by the recall task is stopped
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
  and each auxiliary result count and result body is logged

where test mode is disabled
  then neither the raw query nor memory block is logged

where a generalisation search is supplied
  then it runs alongside the main search and receives at least one third of the main limit
  and successful generalisation facts reach interpretation with regular facts
  if it fails
    then it contributes no facts while regular facts remain eligible
    and successful learning-search facts remain eligible
  while it returns no facts
    then recall proceeds normally

where no generalisation search is supplied
  then no generalisation search is issued
  where a learning search is supplied
    then its successful facts still reach interpretation

where a learning search is supplied
  then it runs on every recall over the same group with the raw query and at least one third of the main limit
  and successful learning facts reach interpretation with regular facts
  if it fails
    then it contributes no facts while regular facts remain eligible
    and successful generalisation-search facts remain eligible
  while it returns no facts
    then recall proceeds normally

where no learning search is supplied
  then no learning search is issued
  where a generalisation search is supplied
    then its successful facts still reach interpretation

where neither auxiliary search is supplied
  then the main search is the only search issued

where both auxiliary searches outlast their yield
  then both are abandoned within one shared five-second window

where both auxiliary searches outlast the outer deadline
  then the outer deadline ends recall before the five-second auxiliary window elapses

when the main result limit is smaller than three
  then each supplied auxiliary search still receives a limit of one
