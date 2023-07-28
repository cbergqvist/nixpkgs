{ lib
, stdenv
, buildPythonPackage
, fetchPypi
, pythonOlder
, hatch-jupyter-builder
, hatchling
, pandoc
, pytestCheckHook
, pytest-console-scripts
, pytest-jupyter
, pytest-timeout
, pytest-tornasync
, argon2-cffi
, jinja2
, tornado
, pyzmq
, flaky
, ipykernel
, traitlets
, jupyter-core
, jupyter-client
, jupyter-events
, jupyter-server-terminals
, nbformat
, nbconvert
, overrides
, send2trash
, terminado
, prometheus-client
, anyio
, websocket-client
, requests
}:

buildPythonPackage rec {
  pname = "jupyter-server";
  version = "2.7.0";
  format = "pyproject";
  disabled = pythonOlder "3.7";

  src = fetchPypi {
    pname = "jupyter_server";
    inherit version;
    hash= "sha256-NtoKJm0xpBrDNaNmyIkzwX36W7gXpI9cAsFtMDvJR38=";
  };

  nativeBuildInputs = [
    hatch-jupyter-builder
    hatchling
  ];

  propagatedBuildInputs = [
    argon2-cffi
    jinja2
    tornado
    pyzmq
    traitlets
    jupyter-core
    jupyter-client
    jupyter-events
    jupyter-server-terminals
    nbformat
    nbconvert
    overrides
    send2trash
    terminado
    prometheus-client
    anyio
    websocket-client
  ];

  nativeCheckInputs = [
    flaky
    ipykernel
    pandoc
    pytestCheckHook
    pytest-console-scripts
    pytest-jupyter
    pytest-timeout
    pytest-tornasync
    requests
  ];

  pytestFlagsArray = [
    "-W" "ignore::DeprecationWarning"
  ];

  preCheck = ''
    export HOME=$(mktemp -d)
    export PATH=$out/bin:$PATH
  '';

  disabledTests = [
    "test_server_extension_list"
    "test_cull_idle"
  ] ++ lib.optionals stdenv.isDarwin [
    # attempts to use trashcan, build env doesn't allow this
    "test_delete"
    # test is presumable broken in sandbox
    "test_authorized_requests"
  ];

  disabledTestPaths = [
    "tests/services/kernels/test_api.py"
    "tests/services/sessions/test_api.py"
    # nbconvert failed: `relax_add_props` kwargs of validate has been
    # deprecated for security reasons, and will be removed soon.
    "tests/nbconvert/test_handlers.py"
  ];

  __darwinAllowLocalNetworking = true;

  meta = with lib; {
    changelog = "https://github.com/jupyter-server/jupyter_server/releases/tag/v${version}";
    description = "The backend—i.e. core services, APIs, and REST endpoints—to Jupyter web applications";
    homepage = "https://github.com/jupyter-server/jupyter_server";
    license = licenses.bsdOriginal;
    maintainers = [ maintainers.elohmeier ];
  };
}
