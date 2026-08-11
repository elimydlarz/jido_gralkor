Journey: replaceable-lens-workflow (journey: test/journey/replaceable_lens_workflow_journey_test.exs)

when an application writes a complete graph through a replaceable Lens
  then searching the Lens's Destination returns the supplied graph
  when the application later replaces it with another complete graph
    then Destination search no longer returns the previous graph
    and Destination search returns the current graph
