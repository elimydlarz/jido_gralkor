Journey: replaceable-lens-workflow (journey: none)

when an application writes a complete graph through a replaceable Lens
  then Lens search returns the supplied graph
  when the application later replaces it with another complete graph
    then Lens search no longer returns the previous graph
    and Lens search returns the current graph
