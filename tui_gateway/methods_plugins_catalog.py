"""Profile-scoped plugin catalog for native clients."""

from .method_ctx import HandlerRegistry, bind_module

_registry = HandlerRegistry()
method = _registry.method
_profile_scoped = _registry.profile_scoped


@method("plugins.catalog")
@_profile_scoped
def _(rid, params):
    from hermes_cli import plugins_cmd, plugins_cmd_catalog
    from hermes_cli.web_server_dashboard import _plugin_runtime_status

    enabled, disabled = plugins_cmd._get_enabled_set(), plugins_cmd._get_disabled_set()
    installed = {}
    for name, _version, _description, _source, directory, key in plugins_cmd._discover_all_plugins():
        aliases = {name, key} - {""}
        row = {"dir": directory, "runtime_status": _plugin_runtime_status(aliases, enabled, disabled)}
        installed.update({alias: row for alias in aliases})
    return _ok(rid, plugins_cmd_catalog.installed_catalog_state(installed))


def register(server):
    bind_module(globals(), server, skip=("_",))
    server._LONG_HANDLERS = server._LONG_HANDLERS | _registry.names()
