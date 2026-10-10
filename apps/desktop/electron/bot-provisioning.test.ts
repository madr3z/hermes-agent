import { describe, expect, it, vi } from 'vitest'

import { registerProvisionedBot } from './bot-provisioning'
import type { ConnectionRegistry } from './connection-registry'

const id = '25d2e87a-80d9-41e2-a154-5fbbfae2bf70'

function fixture() {
  let registry = {
    version: 2,
    primary: 'main',
    launchMode: 'primary',
    lastUsed: 'main',
    connections: [
      { id: 'main', kind: 'remote', label: 'Main', url: 'https://main.example', token: { encrypted: 'sealed' } }
    ]
  } as ConnectionRegistry

  const deps = {
    registry: () => structuredClone(registry),
    request: vi.fn(async () => ({
      phase: 'ready',
      gateway: { id, label: 'Research', base_url: `/api/plugins/bot-provisioning/v1/gateways/${id}` }
    })),
    persist: vi.fn((value: ConnectionRegistry) => {
      registry = value
    }),
    publish: vi.fn(),
    sanitize: (entry: { id: string }) => ({ id: entry.id })
  }

  return deps
}

describe('provisioned gateway registration', () => {
  it('reuses the encrypted parent credential without exposing it or duplicating retries', async () => {
    const deps = fixture()
    const result = await registerProvisionedBot({ connectionId: 'main', requestId: id }, deps)
    await registerProvisionedBot({ connectionId: 'main', requestId: id }, deps)
    expect(result).toEqual({ id: `bot-vm-${id}` })
    expect(deps.registry().connections).toHaveLength(2)
    expect(deps.registry().connections[1].token).toEqual({ encrypted: 'sealed' })
    expect(deps.request).toHaveBeenCalledWith({
      connectionId: 'main',
      profile: 'default',
      path: `/api/plugins/bot-provisioning/v1/requests/${id}`
    })
  })
  it('refuses an upstream-selected URL before copying the main credential', async () => {
    const deps = fixture()
    deps.request.mockResolvedValue({
      phase: 'ready',
      gateway: { id, label: 'Bad', base_url: 'https://attacker.example' }
    })
    await expect(registerProvisionedBot({ connectionId: 'main', requestId: id }, deps)).rejects.toThrow('not ready')
    expect(deps.persist).not.toHaveBeenCalled()
  })
})
