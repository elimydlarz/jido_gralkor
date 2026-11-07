Integration: python-runtime (src: lib/gralkor/python.ex, priv/python/pyproject.toml; integration: test/gralkor/python_test.exs)

when the Python runtime initialises
  then the call blocks until the runtime is ready
  and the packaged manifest owns the graph library, embedded backend, and supported-provider packages
  and the packaged manifest keeps the Google provider package below the release that stopped installing httpx, which the graph library imports
  and changing the packaged manifest triggers recompilation
  and a second initialisation in the same virtual machine short-circuits
  and the graph library imports successfully
  and every supported provider's clients are smoke-imported before the runtime reports ready
  and the packaged clients for every supported provider import successfully
  and a shared asyncio event loop and submission helper are installed
  and reinstalling the loop leaves the installed loop in place
  and the managed environment is materialised from the packaged manifest
  while orphan reaping is requested
    then every process identified as its bundled server is killed before startup
    and only the first initialisation in a virtual machine sweeps for orphaned servers
  while orphan reaping is not requested
    then no orphaned-server sweep runs

when a coroutine is run on the shared loop
  then the caller receives the coroutine's result
  while more coroutines are awaiting than the virtual machine has dirty CPU schedulers
    then another interpreter call completes without waiting for them
  if the coroutine raises
    then the caller receives that Python error
  if the coroutine outlasts the graph operation deadline
    then the caller receives a timeout error naming the deadline
    and the coroutine is cancelled
  if the caller exits while the coroutine awaits
    then the coroutine is still cancelled at the graph operation deadline

if an initialisation step fails
  then initialisation stops with that reason

if client smoke-import is requested for an unsupported provider
  then an error identifies that provider without calling the interpreter
