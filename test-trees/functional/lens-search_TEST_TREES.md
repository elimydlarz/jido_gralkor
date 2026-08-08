Functional: lens-search (functional: test/functional/lens_search_functional_test.exs)

when a caller searches memory
  then results from the requesting operator's reserved `operator` Lens precede additional-Lens results
  and another operator's reserved operator memory cannot contribute a result

where a caller supplies additional Lenses to search
  then the requesting operator's reserved `operator` Lens and every additional Lens are searched concurrently
  and additional results retain their configured Lens order
  and every result identifies the searched Lens that contributed it
  and repeated matches from different groups remain in the response
  and the same maximum result count applies independently to the operator Lens and every additional Lens
  and no unselected local Lens or another operator's local memory can contribute a result

where a caller supplies no additional Lenses to search
  then only the requesting operator's reserved `operator` Lens is searched

where a caller supplies no maximum result count
  then every resolved destination receives the default maximum result count of twenty

where a caller includes the reserved `operator` Lens explicitly
  then the requesting operator's existing group is searched only once

where the selection contains the reserved `global` Lens
  then every relevant globally stored episode may contribute
  and originating Lens does not filter the global results

where the selection names a registered global Lens
  then its group is the shared global group, so the whole global group is searched
  and originating Lens remains attribution rather than a search boundary

where multiple selected Lens names resolve to the shared global group
  then the shared global group is searched only once
  and its results identify the reserved `global` search Lens

if the selected memory search fails
  then the error is returned without manufacturing a partial memory response

if search supplies a maximum result count that is not a positive integer
  then search fails before any memory query is started
  and the error identifies the invalid maximum result count

if search supplies an additional Lens that is neither registered nor reserved
  then search fails before any memory query is started
  and no valid subset is searched
  and the error identifies the unknown Lens

if search supplies the retired `default` Lens name
  then search fails before any memory query is started
  and the error identifies the reserved `operator` Lens as its replacement
