Functional: destination-registration (src: lib/gralkor/destination.ex, lib/gralkor/destination/registry.ex; functional: test/functional/destination_registration_functional_test.exs)

when an application registers a valid Destination
  then Lenses and Reflections can reference that Destination by name
  and the Destination name identifies the graph where their results are saved

where the packaged Destinations are used
  then operator memory references the Destination named `operator`
  and globally shared memory references the Destination named `global`

when multiple Lenses or Reflections reference the same Destination
  then their results are saved to the same Destination

where a replaceable Lens references a shared Destination
  then replacement changes only graph content previously written by that Lens
  and information saved through every other Lens or Reflection remains unchanged

if the Destination registry is not a list
  then configuration resolution raises `ArgumentError` naming what it found instead

if an application registers an invalid Destination
  then configuration resolution raises `ArgumentError` before ingestion, Reflection, or search begins
  and a blank Destination name is identified
  and a duplicate Destination name is identified
  and an invalid Destination definition shape is identified
  and an address setting is identified as unsupported with its Destination
  and an ontology setting is identified as unsupported with its Destination

if a Lens or Reflection references an unknown Destination
  then configuration resolution raises `ArgumentError` identifying the Lens or Reflection and Destination
