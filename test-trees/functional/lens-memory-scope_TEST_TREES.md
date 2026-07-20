Functional: lens-memory-scope (functional: none)

when an operator-local Lens adds an episode
  then its memory destination is determined by the operator and Lens together
  and the episode is unavailable through another local Lens belonging to the same operator
  and the episode is unavailable to another operator using a Lens with the same name
  and the episode is unavailable from shared global memory

when a global Lens adds an episode
  then the episode enters the one global memory pool shared by every global Lens and every operator
  and the same episode submission records the name of its originating Lens
  and the ingestion process does not have to add Lens provenance itself

where a Lens is registered as operator-local or global
  then that scope governs every episode the Lens's ingestion process submits
