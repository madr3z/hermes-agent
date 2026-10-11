import { expect, it, vi } from 'vitest'

import { buildGatewayWsUrlWithTicket } from './connection-config'
import type { RegistryConnection } from './connection-registry'
import { resolveOauthPartition } from './oauth-partition'
import { mintGatewayWsTicket } from './oauth-rest-request'
import { createRegistryGatewayWsUrlHandler } from './remote-ws-headers'

function fixture(primary = 'main') {
  const main: RegistryConnection = {
    id: 'main',
    kind: 'remote',
    label: 'Main',
    authMode: 'oauth',
    url: 'https://main.example/team'
  }

  const requestId = '25d2e87a-80d9-41e2-a154-5fbbfae2bf70'

  const guest: RegistryConnection = {
    ...main,
    id: 'guest',
    label: 'Assistant',
    url: `${main.url}/api/plugins/bot-provisioning/v1/gateways/${requestId}`,
    provisionedVm: { connectionId: main.id, requestId }
  }

  const registry = { primary, connections: [main, guest] }
  const ownerPartition = resolveOauthPartition(main.url, { registry, connectionId: main.id })
  let issued = 0

  const fetchJsonViaOauthSession = vi.fn(async (url: string, options: { method: string; headers: unknown }) => {
    // The controller owns auth; the VM proxy has no ticket-mint route.
    if (url !== `${main.url}/api/auth/ws-ticket`) {
      throw Object.assign(new Error('Gateway route not found'), { statusCode: 404 })
    }

    expect(options.method).toBe('POST')
    expect(options.headers).toEqual({})
    expect(resolveOauthPartition(url, { registry })).toBe(ownerPartition)

    return { ticket: `single-use-${++issued}` }
  })

  const deps = {
    oauthScope: { registry },
    ensureNativeAccessToken: vi.fn(async () => null),
    fetchJson: vi.fn(),
    fetchJsonViaOauthSession
  }

  return { main, guest, registry, deps }
}

it.each(['main', 'local'])(
  'mints each managed VM dial at its controller and keeps its guest socket: primary %s',
  async primary => {
    const f = fixture(primary)

    const handler = createRegistryGatewayWsUrlHandler({
      ensureBackend: async () => ({
        authMode: 'oauth',
        baseUrl: f.guest.url!,
        wsUrl: '',
        sharedRemote: true,
        profile: 'default'
      }),
      mintTicket: baseUrl => mintGatewayWsTicket(baseUrl, f.deps, { 'X-Guest-Only': 'guest-value' }),
      buildTicketUrl: buildGatewayWsUrlWithTicket,
      rememberHeaders: () => {}
    })

    const first = new URL(await handler({ connectionId: f.guest.id, profile: 'default' }))
    const second = new URL(await handler({ connectionId: f.guest.id, profile: 'default' }))
    expect(first.pathname).toBe(new URL(f.guest.url!).pathname + '/api/ws')
    expect(first.searchParams.get('profile')).toBe('default')
    expect(first.searchParams.get('ticket')).not.toBe(second.searchParams.get('ticket'))
    expect(f.deps.ensureNativeAccessToken.mock.calls).toEqual([[f.main.url], [f.main.url]])
    expect(f.deps.fetchJsonViaOauthSession).toHaveBeenCalledTimes(2)
  }
)

it('rejects invalid or ambiguous managed ownership before minting and preserves standalone ticket routes', async () => {
  const edits = [
    (f: ReturnType<typeof fixture>) => {
      f.registry.connections = [f.guest]
    },
    (f: ReturnType<typeof fixture>) => {
      f.main.url = 'https://repointed.example'
    },
    (f: ReturnType<typeof fixture>) => {
      f.guest.provisionedVm!.requestId = 'invalid'
    },
    (f: ReturnType<typeof fixture>) => {
      f.main.authMode = 'token'
    },
    (f: ReturnType<typeof fixture>) => {
      f.registry.connections.push({ ...f.guest, id: 'alias', provisionedVm: undefined })
    },
    (f: ReturnType<typeof fixture>) => {
      f.registry.connections.push({ ...f.main, id: 'alias' })
    }
  ]

  for (const edit of edits) {
    const f = fixture()
    edit(f)
    await expect(mintGatewayWsTicket(f.guest.url!, f.deps)).rejects.toThrow(/owning controller/)
    expect(f.deps.ensureNativeAccessToken).not.toHaveBeenCalled()
    expect(f.deps.fetchJsonViaOauthSession).not.toHaveBeenCalled()
  }

  const f = fixture()
  await expect(mintGatewayWsTicket(f.main.url!, f.deps)).resolves.toBe('single-use-1')
})
