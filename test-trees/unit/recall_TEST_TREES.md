Unit: recall (src: lib/gralkor/recall.ex; integration: test/gralkor/recall_test.exs; unit: test/gralkor/recall_test.exs)

when a recall is requested
  then the group id is sanitised by replacing hyphens with underscores before any search runs
  and the returned memory block wraps its body in `<gralkor-memory trust="untrusted">…</gralkor-memory>`
  and the memory block carries an instruction to search memory again when more detail is needed
  if the agent name is missing or blank
    then an ArgumentError is raised

when interpretation selects relevant facts
  then the memory block body lists them one per line
  and each entry is the interpreted line verbatim, preserving every timestamp parenthetical
  and each entry ends with ' — ' followed by a one-sentence relevance reason

when the graph search returns no facts
  then the memory block body is "No relevant memories found."

when interpretation selects none of the searched facts
  then the memory block body is "No relevant memories found."

if the main graph search fails
  then the failure reason is returned to the caller
  and no memory block is manufactured

when a non-blank session id is supplied
  then the conversation context is the buffered turns for that session, flat-walked in order
  and user turns are labelled "User"
  and assistant turns are labelled with the agent name rather than "Assistant"

when a nil session id is supplied
  then the conversation context is empty
  and the turn buffer is never consulted

when a maximum result count is supplied
  then at most that many facts are searched for

when no maximum result count is supplied
  then a default of 10 facts is searched for

when an output token budget is supplied
  then that budget is forwarded to interpretation

when no output token budget is supplied
  then interpretation applies its own default budget of 2000

where a generalisation search is supplied
  then it runs in parallel with the main search over the same sanitised group
  and it asks for one third of the main result limit, never fewer than one
  and its results are combined with the regular facts before interpretation
  and it is abandoned after a five-second yield that is independent of the overall recall deadline
  if it fails or times out
    then recall proceeds with only the regular facts

where no generalisation search is supplied
  then no generalisation search is issued
  and recall still returns its memory block from the main search alone

where a learning search is supplied
  then it runs on every recall without any opt-in flag
  and it runs in parallel over the same sanitised group
  and it is seeded with the raw user query rather than a classified or LLM-rewritten query
  and it asks for one third of the main result limit, never fewer than one
  and its results are combined with the regular facts before interpretation
  and it is abandoned after a five-second yield that is independent of the overall recall deadline
  if it fails or times out
    then recall proceeds with only the regular facts

where no learning search is supplied
  then no learning search is issued
  and the main search remains the only query sent to the graph

when recall runs through the production client wiring
  then the learning search reaches the graph as a node search restricted to the node label "Learning"
  and each returned learning node is rendered from its name, summary, and attributes
  and no learning-search failure is logged

while a deadline budget governs the call
  if the upstream answers inside the budget
    then the memory block is returned normally
  if the budget is exhausted before the call returns
    then in-flight upstream work is cancelled
    and {:error, :recall_deadline_expired} is returned

when no deadline is supplied
  then a default budget of 12 seconds governs the call

when a recall begins
  then the session is logged
  and the group is logged
  and the query length is logged
  and the search result limit is logged

when the recall call completes
  then how many facts were found is logged
  and the resulting block size is logged
  and how long the search took is logged
  and how long interpretation took is logged
  where interpretation never ran
    then the logged interpretation duration is zero

where test mode is enabled
  then the raw query is also logged
  and every auxiliary search that runs logs how many results it returned
  and every auxiliary search that runs logs the results themselves
  when facts are returned
    then the resulting memory block is also logged
  when no facts are returned
    then no memory block is logged

where test mode is disabled
  then the raw query is not logged
  and the memory block is not logged
