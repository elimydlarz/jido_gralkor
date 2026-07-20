Functional: lens-search (functional: test/functional/lens_search_functional_test.exs)

when a caller searches memory
  then the requesting operator's reserved `default` destination is always searched first
  and another operator's default memory cannot contribute a result

where a caller supplies additional operator-local Lens or reserved `global` targets
  then every additional target is searched after the requesting operator's reserved `default` destination
  and additional results retain their configured target order
  and repeated matches from different destinations remain in the response
  and the same maximum result count applies independently to the default and every additional destination
  and no unselected local Lens or another operator's local memory can contribute a result

where a caller supplies no additional search targets
  then only the requesting operator's reserved `default` destination is searched

where a caller includes the reserved `default` target explicitly
  then the requesting operator's default destination is searched only once

where the selection contains the reserved `global` target
  then every relevant globally stored episode may contribute
  and originating Lens does not filter the global results

where a global Lens name identifies an episode's origin
  then that name remains attribution rather than a search boundary
  and `global` is the only target that selects globally stored memory

if the selected memory search fails
  then the error is returned without manufacturing a partial memory response

if search supplies an additional target that is neither a registered operator-local Lens nor reserved `default` or `global`
  then search fails before any memory query is started
  and no valid subset is searched
  and the error identifies the invalid target
