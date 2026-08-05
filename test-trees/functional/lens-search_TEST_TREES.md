Functional: lens-search (functional: test/functional/lens_search_functional_test.exs)

when a caller searches memory
  then the requesting operator's reserved `default` Lens is always searched first
  and another operator's default memory cannot contribute a result

where a caller supplies additional Lenses to search
  then every additional Lens is searched after the requesting operator's reserved `default` Lens
  and additional results retain their configured Lens order
  and repeated matches from different groups remain in the response
  and the same maximum result count applies independently to the default and every additional Lens
  and no unselected local Lens or another operator's local memory can contribute a result

where a caller supplies no additional Lenses to search
  then only the requesting operator's reserved `default` Lens is searched

where a caller includes the reserved `default` Lens explicitly
  then the requesting operator's default group is searched only once

where the selection contains the reserved `global` Lens
  then every relevant globally stored episode may contribute
  and originating Lens does not filter the global results

where the selection names a registered global Lens
  then its group is the shared global group, so the whole global group is searched
  and originating Lens remains attribution rather than a search boundary

if the selected memory search fails
  then the error is returned without manufacturing a partial memory response

if search supplies an additional Lens that is neither registered nor reserved
  then search fails before any memory query is started
  and no valid subset is searched
  and the error identifies the unknown Lens
