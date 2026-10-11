import { uniqueLabel } from './connection-registry'
import type { ConnectionRegistry, RegistryConnection } from './connection-registry'

interface ReadyStatus {
  phase: string
  gateway?: { id: string; base_url: string; label: string }
}

/** Registration retains native main credentials; cookie guests use the verified parent jar. */
export async function registerProvisionedBot(
  payload: { connectionId: string; requestId: string },
  deps: {
    registry: () => ConnectionRegistry
    request: (request: { connectionId: string; profile: string; path: string }) => Promise<ReadyStatus>
    persist: (registry: ConnectionRegistry) => void
    publish: (id: string) => void
    sanitize: (entry: RegistryConnection) => unknown
  }
) {
  if (!/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(payload.requestId)) {
    throw new Error('Invalid provisioning request ID')
  }

  const registry = deps.registry()
  const source = registry.connections.find(entry => entry.id === payload.connectionId)

  if (!source || source.kind !== 'remote' || source.provisionedVm) {
    throw new Error('Connect to the main provisioning gateway using its HTTPS URL first.')
  }

  const base = new URL(source.url || '')

  if (base.protocol !== 'https:') {
    throw new Error('Provisioning requires an HTTPS main gateway.')
  }

  const status = await deps.request({
    connectionId: source.id,
    profile: 'default',
    path: `/api/plugins/bot-provisioning/v1/requests/${payload.requestId}`
  })

  const expected = `/api/plugins/bot-provisioning/v1/gateways/${payload.requestId}`

  if (status.phase !== 'ready' || status.gateway?.id !== payload.requestId || status.gateway?.base_url !== expected) {
    throw new Error('The bot gateway is not ready for registration.')
  }

  // Refresh after awaiting: another registry edit must never be lost.
  const latest = deps.registry()
  const current = latest.connections.find(entry => entry.id === source.id)

  if (
    !current ||
    current.url !== source.url ||
    current.kind !== source.kind ||
    current.authMode !== source.authMode ||
    JSON.stringify(current.token) !== JSON.stringify(source.token)
  ) {
    throw new Error('Main gateway changed. Retry registration.')
  }

  const id = `bot-vm-${payload.requestId}`

  const entry = {
    ...current,
    id,
    label: uniqueLabel(
      status.gateway.label,
      latest.connections.filter(item => item.id !== id).map(item => item.label)
    ),
    url: (source.url || '').replace(/\/$/, '') + expected,
    remoteProfile: 'default',
    provisionedVm: { connectionId: source.id, requestId: payload.requestId },
    installId: undefined
  }

  const index = latest.connections.findIndex(item => item.id === id)

  if (index < 0) {
    latest.connections.push(entry)
  } else {
    latest.connections[index] = entry
  }

  deps.persist(latest)
  deps.publish(id)

  return deps.sanitize(entry)
}
