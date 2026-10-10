export async function listConnections() {
  const bridge = window.hermesDesktop?.connections

  if (!bridge) {
    throw new Error('This Desktop build has no connection registry. Update Hermes Desktop.')
  }

  const registryPayload = await bridge.list()
  const rows = Array.isArray(registryPayload?.connections) ? registryPayload.connections : []

  return rows.map(connection => ({ ...connection, primary: connection.id === registryPayload.primary }))
}
