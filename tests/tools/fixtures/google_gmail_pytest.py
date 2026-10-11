"""Optional path to a separately prepared, pinned provider test runtime."""


def pytest_addoption(parser):
    parser.addoption("--gmail-provider-python", help="Pinned Workspace MCP runtime Python.")
