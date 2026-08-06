Unit: python-runtime (src: lib/gralkor/python.ex; integration: test/gralkor/python_test.exs; unit: test/gralkor/python_test.exs)

when the Python runtime is initialised
  then initialisation runs to completion synchronously and returns only once the runtime is ready
  and the package's manifest declares the graph library, the embedded FalkorDB backend, and the provider packages for every supported inference provider, so a consumer configures nothing about Python
  and the package's manifest is a compile-time external resource, so editing its dependency set triggers recompilation
  and a second initialisation in the same virtual machine short-circuits, so repeated boots cannot trip the interpreter's already-initialised guard
  and a smoke import of the graph library succeeds
  and the provider client for each supported inference provider imports successfully, so an unsupported provider selection fails on its configuration rather than on a missing package
  and a shared asyncio event loop is installed on a daemon thread together with a helper that submits work onto it
  and re-invoking the loop installation leaves the already-installed loop in place
  while the managed virtual environment is absent
    then it is materialised
  while an embedded connection is configured
    then any process whose arguments identify the embedded backend's bundled server is killed first, so a server orphaned by a hard virtual-machine exit cannot survive
    and only the first initialisation in a virtual machine sweeps, so a later one cannot kill a server this virtual machine has already started
  while a remote connection is configured
    then no orphaned-server sweep runs

if any initialisation step fails
  then initialisation stops with the reason, so the supervisor restarts it and a permanent failure eventually exits the virtual machine

if a caller asks to smoke-import clients for an unsupported provider
  then the error identifies that unsupported provider without calling the interpreter
