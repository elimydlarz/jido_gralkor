Functional: lens-search (functional: none)

when a caller searches a non-empty selection of operator-local Lenses and reserved `default` or `global` targets
  then results are returned from every selected destination belonging to the requesting operator
  and results retain the requested target order without deduplicating repeated matches
  and the same maximum result count applies independently to every selected destination
  and no unselected local Lens or another operator's local memory can contribute a result

where the selection contains the reserved `global` target
  then every relevant globally stored episode may contribute
  and originating Lens does not filter the global results

where a global Lens name identifies an episode's origin
  then that name remains attribution rather than a search boundary
  and `global` is the only target that selects globally stored memory

if the selected memory search fails
  then the error is returned without manufacturing a partial memory response

if search supplies an invalid target selection
  then search fails before any memory query is started
  and no valid subset is searched
    where the selection is empty
      then the error identifies that at least one target is required
    where a target is neither a registered operator-local Lens nor reserved `default` or `global`
      then the error identifies the invalid target
