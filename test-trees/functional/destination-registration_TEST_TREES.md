Functional: destination-registration (src: lib/gralkor/destination.ex, lib/gralkor/destination/registry.ex, lib/jido_gralkor/runtime.ex; functional: test/functional/destination_registration_functional_test.exs)

when an application registers a valid Destination
  then Lenses and Reflections can reference that Destination by name
  and the Destination name identifies the graph where their results are saved

where the packaged Destinations are used
  then personal memory references the Destination named `personal`
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
  and a Destination name beginning `personal/` or `operator/` is identified as reserved
  and a duplicate Destination name is identified
  and an invalid Destination definition shape is identified
  and an address setting is identified as unsupported with its Destination
  and an ontology setting is identified as unsupported with its Destination

if a Lens or Reflection references an unknown Destination
  then configuration resolution raises `ArgumentError` identifying the Lens or Reflection and Destination

if the application registers the retired operator Destination
  then configuration resolution identifies personal as its replacement before any memory operation

if the application registers a Destination named personal
  then configuration resolution refuses to replace the packaged private Destination
