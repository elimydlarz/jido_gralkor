Journey: application-lens-workflow (journey: none)

when an application registers operator-local observation and decision Lenses and a global generalisation Lens
  then direct consumers and the mounted memory plugin use the same application-owned Lens definitions
    when a consumer ingests an observation without starting an agent turn
      then the observation becomes searchable only through that operator's observation Lens
    when an agent records a decision through a turn-selected Lens
      then the decision becomes searchable through that operator's decision Lens rather than the plugin's default Lens
    when the agent's completed turn is also submitted through the generalisation Lens
      then durable generalisations enter shared global memory with their originating Lens recorded
    when the agent searches its selected local Lenses and global memory
      then one memory response contains relevant results from exactly those selected destinations
      and another operator's local memory is absent

if the application selects an unknown Lens or invalid search target
  then the operation fails before memory is ingested or searched
