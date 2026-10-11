import { afterEach, expect, it, vi } from 'vitest'

import { displayRequest, resolveScreenWsUrl, retainBotScreen } from '../plugins/hermes-bots/screen-connection'

import { botVmClient, botVmOwner } from './bot-vm'
const mocks = vi.hoisted(() => ({ request: vi.fn(), resolveUrl: vi.fn(), retain: vi.fn() }))
vi.mock('@hermes/plugin-sdk', () => ({
  host: {
    botVm: (owner: Parameters<typeof botVmClient>[0]) => botVmClient(owner),
    botVmOwner: (id: string) => botVmOwner(id),
    requestProfile: mocks.request,
    retainProfile: mocks.retain
  },
  resolveSiblingWsUrl: mocks.resolveUrl
}))
vi.mock('../plugins/hermes-bots/routing', () => ({
  resolveBotConnectionRoute: () => ({
    status: 'resolved',
    route: {
      connectionId: 'guest',
      profile: 'default',
      targetProfile: 'default',
      mode: 'remote'
    }
  })
}))
afterEach(() => {
  Reflect.deleteProperty(window, 'hermesDesktop')
  vi.clearAllMocks()
})
it('blocks screen refresh, lease control and attachment when the captured VM connection is edited in Settings', async () => {
  const requestId = '25d2e87a-80d9-41e2-a154-5fbbfae2bf70'
  const main = { id: 'main', kind: 'remote', url: 'https://main.example' }

  let rows = [
    main,
    {
      id: 'guest',
      kind: 'remote',
      url: `${main.url}/api/plugins/bot-provisioning/v1/gateways/${requestId}`,
      provisionedVm: { connectionId: 'main', requestId }
    }
  ]

  Object.defineProperty(window, 'hermesDesktop', {
    configurable: true,
    value: {
      connections: { list: async () => ({ connections: rows }) }
    }
  })
  const vmOwner = (await botVmOwner('guest'))!
  const bot = { name: 'default', connectionId: 'guest', vmOwner }
  await displayRequest(bot, 'display.status')
  expect(mocks.request).toHaveBeenCalledTimes(1)
  rows = [main, { id: 'guest', kind: 'remote', url: 'https://unrelated.example' }]

  for (const method of [
    'display.status',
    'display.observe',
    'display.start',
    'display.lease.acquire',
    'display.lease.release'
  ]) {
    await expect(displayRequest(bot, method)).rejects.toThrow('owner changed')
  }

  await expect(retainBotScreen(bot)).rejects.toThrow('owner changed')
  await expect(resolveScreenWsUrl(bot, 'ticket')).rejects.toThrow('owner changed')
  expect(mocks.request).toHaveBeenCalledTimes(1)
  expect(mocks.retain).not.toHaveBeenCalled()
  expect(mocks.resolveUrl).not.toHaveBeenCalled()
})
