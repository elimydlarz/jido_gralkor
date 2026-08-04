Unit: agent-learning (src: lib/gralkor/agent_learning.ex; unit: test/gralkor/agent_learning_test.exs)

when a learning record is built
  then it carries the kind of problem approached, the approach taken, whether the approach succeeded, and the lesson learned
  and no field links it to another learning record, so recalling a learning is never a graph traversal

when a learning record is rendered into the episode body written to the graph
  then the body states the problem kind verbatim, so a problem-kind-seeded hybrid search surfaces it
  and the body carries the approach verbatim
  and the body carries the lesson verbatim, so the domain entities it names stay linkable
  while the record says the approach succeeded
    then the body states the outcome as having succeeded
  while the record says the approach did not succeed
    then the body states the outcome as not having succeeded
    but the body never uses the word "succeeded", so the success bias stays unambiguous
