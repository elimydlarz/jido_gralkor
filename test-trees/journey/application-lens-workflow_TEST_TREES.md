Journey: application-lens-workflow (journey: test/journey/application_lens_workflow_journey_test.exs)

when an application runs a workflow across registered local and global Lenses
  then application-owned Lens identity and scope are preserved throughout the workflow

if the application selects an unknown Lens
  then the operation fails before memory is ingested or searched
