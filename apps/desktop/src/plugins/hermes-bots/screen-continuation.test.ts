import { beforeEach, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  owner: { connectionId: 'guest-a', profile: 'default' },
  request: vi.fn(),
  open: vi.fn(),
  display: vi.fn(),
  route: { connectionId: 'guest-a', profile: 'default', mode: 'remote' as const }
}))
vi.mock('@hermes/plugin-sdk', () => ({
  host: {
    state: {
      focusedSessionOwner: { get: () => mocks.owner },
      focusedSessionId: { get: () => 'runtime-original' },
      focusedStoredSessionId: { get: () => 'stored-original' }
    },
    requestProfile: mocks.request,
    openSession: mocks.open
  }
}))
vi.mock('./screen-connection', () => ({ botScreenRoute: () => mocks.route, displayRequest: mocks.display }))

import { captureScreenTask, continueScreenTask } from './screen-continuation'

beforeEach(() => {
  mocks.owner = { connectionId: 'guest-a', profile: 'default' }
  mocks.request.mockReset()
  mocks.open.mockReset()
  mocks.display.mockReset()
  mocks.display.mockResolvedValue({ lease: { holder: 'agent' } })
})

it('refuses a focused chat owned by another bot or connection', () => {
  mocks.owner = { connectionId: 'guest-b', profile: 'default' }
  expect(captureScreenTask({ name: 'default' })).toBeNull()
  mocks.owner = { connectionId: 'guest-a', profile: 'other-bot' }
  expect(captureScreenTask({ name: 'default' })).toBeNull()
})

it('keeps original chat and sends once after an uncertain prompt acknowledgement', async () => {
  const bot = { name: 'default' },
    task = captureScreenTask(bot)!
  mocks.request.mockRejectedValueOnce(new Error('reply lost'))
  await expect(continueScreenTask(bot, task)).rejects.toThrow('reply lost')
  mocks.owner = { connectionId: 'guest-b', profile: 'other-bot' }
  mocks.display.mockResolvedValue({ lease: { holder: 'human' } })
  await continueScreenTask(bot, task)
  expect(mocks.request).toHaveBeenCalledTimes(1)
  expect(mocks.request).toHaveBeenCalledWith(
    mocks.route,
    'prompt.submit',
    expect.objectContaining({ session_id: 'runtime-original' })
  )
  expect(mocks.open).toHaveBeenCalledWith('stored-original', { route: mocks.route })
  expect(mocks.display).toHaveBeenCalledTimes(1)
})

it('blocks task admission while human control remains', async () => {
  mocks.display.mockResolvedValue({ lease: { holder: 'human' } })
  await expect(continueScreenTask({ name: 'default' }, captureScreenTask({ name: 'default' })!)).rejects.toThrow(
    'still controls'
  )
  expect(mocks.request).not.toHaveBeenCalled()
})
