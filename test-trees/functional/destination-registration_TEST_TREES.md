Functional: destination-registration (src: none; functional: none)

when an application registers a valid Destination
  then Lenses and Reflections can reference that Destination by name
  and the Destination address determines the graph ID where their results are saved

where a Destination uses the `operator` address
  then its graph ID resolves to the requesting operator

where a Destination uses the `global` address
  then its graph ID resolves to the shared global graph

where a Destination uses an explicit graph ID as its address
  then that graph ID is used without treating it as a scope

where a Destination omits an ontology
  then the Destination uses jido_gralkor's built-in default ontology

where a Destination declares an application ontology
  then extraction for every episode stored in that Destination uses the declared ontology

when multiple Lenses or Reflections reference the same Destination
  then their results are saved to the same Destination

where a replaceable Lens references a shared Destination
  then graph replacement changes only the episodes written by that Lens

if the Destination registry is not a list
  then configuration resolution raises `ArgumentError` naming what it found instead

if an application registers an invalid Destination
  then configuration resolution raises `ArgumentError` before ingestion, Reflection, or search begins
  and a blank Destination name is identified
  and a duplicate Destination name is identified
  and an invalid Destination definition shape is identified
  and a missing or invalid Destination address is identified with its Destination
  and an invalid Destination ontology is identified with its Destination

if a Lens or Reflection references an unknown Destination
  then configuration resolution raises `ArgumentError` identifying the Lens or Reflection and Destination
