import { afterEach, expect, it, vi } from 'vitest'

import { setApiRequestConnection, setApiRequestProfile } from '@/api/client'

import { botVmClient, botVmOwner, resolveBotVmOwner } from './bot-vm'

const requestId = '25d2e87a-80d9-41e2-a154-5fbbfae2bf70'
const main = { id: 'main', kind: 'remote', label: 'Main', url: 'https://main.example', authMode: 'token' }

const guest = {
  id: 'guest-a',
  kind: 'remote',
  label: 'A',
  url: `${main.url}/api/plugins/bot-provisioning/v1/gateways/${requestId}`,
  provisionedVm: { connectionId: 'main', requestId }
}

afterEach(() => {
  vi.unstubAllGlobals()
  Reflect.deleteProperty(window, 'hermesDesktop')
})
it('keeps lifecycle on the captured main while terminal uses its guest, independent of active gateway', async () => {
  let rows = [main, guest]
  const api = vi.fn(async () => ({}))

  const getConnectionFor = vi.fn(async () => ({
    mode: 'remote',
    authMode: 'token',
    baseUrl: guest.url,
    token: 'main-secret'
  }))

  const getGatewayWsUrlFor = vi.fn(async () => ({
    ok: true,
    wsUrl: guest.url.replace('https:', 'wss:') + '/api/ws?token=main-secret'
  }))

  Object.defineProperty(window, 'hermesDesktop', {
    configurable: true,
    value: {
      connections: { list: async () => ({ connections: rows }) },
      api,
      getConnection: vi.fn(),
      getConnectionFor,
      getGatewayWsUrlFor
    }
  })
  const owner = await botVmOwner('guest-a')
  expect(owner).not.toBeNull()
  const client = botVmClient(owner!)
  setApiRequestConnection('other-vm')
  setApiRequestProfile('other-profile')
  const operation = { operation_id: crypto.randomUUID(), action: 'restart' as const }
  await client.power(operation)
  expect(api).toHaveBeenLastCalledWith({
    connectionId: 'main',
    profile: 'default',
    priority: 'foreground',
    path: `/api/plugins/bot-provisioning/v1/requests/${requestId}/power`,
    method: 'POST',
    body: operation
  })
  const url = new URL(await client.terminalUrl())
  expect(url.pathname).toBe(`/api/plugins/bot-provisioning/v1/gateways/${requestId}/api/terminal/ws`)
  expect(url.searchParams.get('token')).toBe('main-secret')
  expect(getConnectionFor).toHaveBeenCalledWith({ connectionId: 'guest-a', profile: 'default' })
  api.mockRejectedValueOnce(new Error('404: Not Found'))
  expect(await client.terminalStatus()).toMatchObject({ available: false })
  getGatewayWsUrlFor.mockResolvedValueOnce({ ok: true, wsUrl: 'wss://unrelated.example/api/ws?token=other' })
  await expect(client.terminalUrl()).rejects.toThrow('owner changed')
  rows = [main]
  await expect(client.power(operation)).rejects.toThrow('owner changed')
  expect(api).toHaveBeenCalledTimes(2)
})
it('does not infer VM ownership from a name or URL, and refuses a repointed main', () => {
  expect(resolveBotVmOwner([main, { ...guest, provisionedVm: undefined }], guest.id)).toBeNull()
  expect(resolveBotVmOwner([{ ...main, url: 'https://different.example' }, guest], guest.id)).toBeNull()
})
