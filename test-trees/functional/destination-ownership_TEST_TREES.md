Functional: destination-ownership (src: none; functional: none)

when an application defines a Lens or Reflection with an inline destination
  then the resolved owner carries a first-class Destination named after that Lens or Reflection
  and the Destination namespace distinguishes Lens memory from Reflection artefacts
  and the Destination scope governs operator-local or global placement

where an appending Lens or Reflection destination omits an ontology
  then the Destination uses jido_gralkor's built-in default ontology

where an appending Lens or Reflection destination declares an application ontology
  then extraction for writes to that Destination uses the declared ontology

where a replaceable Lens defines a destination
  then the Destination accepts complete graph replacement without an extraction ontology

if a replaceable Lens destination declares an ontology
  then configuration resolution raises `ArgumentError` identifying that the destination does not extract episodes

if a Lens or Reflection destination is missing or malformed
  then configuration resolution raises `ArgumentError` identifying its owner and destination

if a Lens or Reflection destination has neither operator nor global scope
  then configuration resolution raises `ArgumentError` identifying its owner and destination scope

if a Lens or Reflection destination declares a module that is not an ontology
  then configuration resolution raises `ArgumentError` identifying its owner and destination ontology

if a Lens and Reflection have the same name
  then their distinct Destination namespaces prevent their storage from colliding
