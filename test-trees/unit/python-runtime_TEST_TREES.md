Unit: python-runtime (src: lib/gralkor/python.ex; unit: test/gralkor/python_test.exs)

when the Python runtime is initialised
  then initialisation runs to completion synchronously and returns only once the runtime is ready
  and the interpreter is pointed at the managed virtual environment
  and the graph library, the FalkorDB backend, and the provider packages for every supported inference provider are installed from the manifest the package itself ships, so a consumer configures nothing about Python
  and editing that manifest triggers recompilation, so a changed dependency set is picked up
  and the virtual environment is built into the interpreter's own cache at runtime on first boot rather than into the application's private directory
  and a second initialisation in the same virtual machine short-circuits, so repeated boots cannot trip the interpreter's already-initialised guard
  and a smoke import of the graph library succeeds
  and the provider client for each supported inference provider imports successfully, so an unsupported provider selection fails on its configuration rather than on a missing package
  and a shared asyncio event loop is installed on a daemon thread together with a helper that submits work onto it
  and every later block that drives the graph library submits through that helper, so a connection bound to one loop is never awaited on another
  and re-invoking the loop installation leaves the already-installed loop in place
  while the managed virtual environment is absent
    then it is materialised
  while an embedded connection is configured
    then any process whose arguments identify the embedded backend's bundled server is killed first, so a server orphaned by a hard virtual-machine exit cannot survive
    but the sweep matches on arguments alone, so a live server belonging to an earlier runtime in this same virtual machine is killed too, leaving that older graph's next query with a refused connection
  while a remote connection is configured
    then no orphaned-server sweep runs
    and the embedded backend is never imported

if any initialisation step fails
  then initialisation stops with the reason, so the supervisor restarts it and a permanent failure eventually exits the virtual machine

when the Python runtime has booted
  then no health probe runs, so a later runtime failure surfaces from the next call into the interpreter
