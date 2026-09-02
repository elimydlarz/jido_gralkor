Unit: python-runtime (src: lib/gralkor/python.ex, priv/python/pyproject.toml; integration: test/gralkor/python_test.exs; unit: test/gralkor/python_test.exs)

when the Python runtime initialises
  then the call blocks until the runtime is ready
  and the packaged manifest owns the graph library, embedded backend, and supported-provider packages
  and changing the packaged manifest triggers recompilation
  and a second initialisation in the same virtual machine short-circuits
  and the graph library imports successfully
  and every supported provider's clients are smoke-imported before the runtime reports ready
  and the packaged clients for every supported provider import successfully
  and a shared asyncio event loop and submission helper are installed
  and reinstalling the loop leaves the installed loop in place
  while the managed virtual environment is absent
    then it is materialised
  while the embedded backend is configured
    then every process identified as its bundled server is killed before startup
    and only the first initialisation in a virtual machine sweeps for orphaned servers
  while the remote backend is configured
    then no orphaned-server sweep runs

if an initialisation step fails
  then initialisation stops with that reason

if client smoke-import is requested for an unsupported provider
  then an error identifies that provider without calling the interpreter
