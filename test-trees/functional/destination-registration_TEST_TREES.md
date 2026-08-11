Functional: destination-registration (src: lib/gralkor/destination.ex, lib/gralkor/destination/registry.ex; functional: test/functional/destination_registration_functional_test.exs)

when an application registers a valid Destination
  then Lenses and Reflections can reference that Destination by name
  and the Destination address determines the graph ID where their results are saved

where a Destination address has the form `operator/path`
  then its graph ID combines the requesting operator with the address path
  and another operator using the same Destination resolves a different graph ID

where a Destination address has the form `global/path`
  then every operator using that Destination resolves the same graph ID for the address path

where a Destination omits an ontology
  then the Destination uses jido_gralkor's built-in default ontology

where a Destination declares an application ontology
  then extraction for every episode stored in that Destination uses the declared ontology

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
  and a missing or invalid Destination address is identified with its Destination
  and an address with neither `operator` nor `global` scope is identified with its Destination
  and an address with a blank path is identified with its Destination
  and an invalid Destination ontology is identified with its Destination

if a Lens or Reflection references an unknown Destination
  then configuration resolution raises `ArgumentError` identifying the Lens or Reflection and Destination
