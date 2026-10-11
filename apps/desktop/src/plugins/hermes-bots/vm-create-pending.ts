import { type BotVmRequest, readKey, writeKey } from '@hermes/plugin-sdk'

export type PendingVmCreate = Omit<BotVmRequest, 'linux_password'>

function key(scope: string) {
  return `hermes-desktop-vm-create-v1:${encodeURIComponent(scope)}`
}

export function readPendingCreate(scope: string): PendingVmCreate | null {
  const raw = readKey(key(scope))

  if (!raw) {
    return null
  }

  try {
    const value = JSON.parse(raw) as PendingVmCreate

    if (
      !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.request_id) ||
      typeof value.name !== 'string' ||
      typeof value.credentials?.copy !== 'boolean' ||
      value.credentials.source_profile !== 'default' ||
      !['cpu', 'memory_mib', 'disk_gib'].every(key =>
        Number.isInteger(value.resources?.[key as keyof typeof value.resources])
      )
    ) {
      return null
    }

    return {
      request_id: value.request_id,
      name: value.name,
      resources: {
        cpu: value.resources.cpu,
        memory_mib: value.resources.memory_mib,
        disk_gib: value.resources.disk_gib
      },
      credentials: { copy: value.credentials.copy, source_profile: 'default' }
    }
  } catch {
    return null
  }
}

export function persistPendingCreate(scope: string, request: PendingVmCreate | null) {
  // Project the fields explicitly. A request carrying a password must never reach storage.
  const safe = request && {
    request_id: request.request_id,
    name: request.name,
    resources: {
      cpu: request.resources.cpu,
      memory_mib: request.resources.memory_mib,
      disk_gib: request.resources.disk_gib
    },
    credentials: { copy: request.credentials.copy, source_profile: 'default' }
  }

  const serialized = safe ? JSON.stringify(safe) : null

  writeKey(key(scope), serialized)

  if (safe && readKey(key(scope)) !== serialized) {
    throw new Error('Cannot save the pending creation request.')
  }
}
