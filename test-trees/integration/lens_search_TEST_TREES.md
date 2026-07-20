Integration: Lens search (integration: none)

when a caller searches a non-empty selection of operator-local Lenses and reserved `default` or `global` targets
  then the selection resolves to memory destinations belonging to the requesting operator
  and all selected destinations are searched through one Graphiti multi-group search
  and results are combined in requested target order without deduplicating repeated matches
  and the same maximum result count applies independently to every selected destination
  and no unselected local Lens or another operator's local memory can contribute a result

where the selection contains the reserved `global` target
  then every globally stored episode may contribute based on relevance
  and originating Lens does not filter the global results

where a global Lens name identifies an episode's origin
  then that name remains attribution rather than a search boundary
  and `global` is the only target that selects globally stored memory

if Graphiti's multi-group search fails
  then the error is returned without manufacturing a partial memory response

if search supplies an empty selection or a target that is neither a registered operator-local Lens nor reserved `default` or `global`
  then search fails before any memory query is started
  and no valid subset is searched
