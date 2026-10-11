import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ComponentProps, ReactNode } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

import { CreateBotDialog } from './create-agent-dialog'
import { vmEn } from './vm-i18n'

const mocks = vi.hoisted(() => ({ active: 'main', api: vi.fn(), list: vi.fn(), register: vi.fn() }))
vi.mock('@/store/gateway', () => ({ activeGatewayConnectionId: () => mocks.active }))
vi.mock('../../sdk/connections', () => ({ listConnections: async () => (await mocks.list()).connections }))
vi.mock('@/api/client', () => ({ hermesApiAs: (...args: unknown[]) => mocks.api(...args) }))
vi.mock('@hermes/plugin-sdk', async () => {
  const { botProvisioningClient } = await import('../../sdk/bot-provisioning')
  const Container = ({ children }: { children?: ReactNode }) => <div>{children}</div>

  return {
    Button: ({ variant: _variant, ...props }: ComponentProps<'button'> & { variant?: string }) => <button {...props} />,
    Input: (props: ComponentProps<'input'>) => <input {...props} />,
    Checkbox: () => <input type="checkbox" />,
    Dialog: Container,
    DialogContent: Container,
    DialogDescription: Container,
    DialogFooter: Container,
    DialogHeader: Container,
    DialogTitle: Container,
    host: { botProvisioning: botProvisioningClient, notify: vi.fn() }
  }
})
vi.mock('./create-dialog', () => ({ CreateAgentDialog: () => <button>Create profile</button> }))
vi.mock('./i18n', () => ({ useBots: () => ({ vm: vmEn }) }))

const main = { id: 'main', kind: 'remote', label: 'Main', url: 'https://main.example', authMode: 'token' }
const requestId = '25d2e87a-80d9-41e2-a154-5fbbfae2bf70'

const guest = {
  id: 'guest',
  kind: 'remote',
  label: 'Guest',
  url: `${main.url}/api/plugins/bot-provisioning/v1/gateways/${requestId}`,
  provisionedVm: { connectionId: main.id, requestId }
}

const capabilities = {
  available: true,
  resources: {
    cpu: { min: 1, max: 4, default: 2 },
    memory_mib: { min: 2048, max: 4096, default: 2048 },
    disk_gib: { min: 20, max: 40, default: 20 }
  },
  credential_keys: []
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.active = 'main'
  mocks.list.mockResolvedValue({ connections: [main, guest] })
  Object.defineProperty(window, 'hermesDesktop', {
    configurable: true,
    value: { connections: { list: mocks.list, registerProvisioned: mocks.register } }
  })
  mocks.api.mockImplementation(async (_owner, request) => {
    if (request.path.endsWith('/capabilities')) {return capabilities}

    if (request.method === 'POST') {return { ...request.body, phase: 'queued' }}

    return { requests: [] }
  })
})
afterEach(() => {
  cleanup()
  Reflect.deleteProperty(window, 'hermesDesktop')
})

function open() {
  return render(<CreateBotDialog onClose={() => undefined} open roster={[]} />)
}

async function create() {
  fireEvent.change(await screen.findByLabelText(vmEn.name), { target: { value: 'research' } })
  fireEvent.click(screen.getByRole('button', { name: vmEn.create }))
}

it.each(['main', 'guest'])(
  'opens resource creation by default on %s and sends the request to its captured main',
  async selected => {
    mocks.active = selected
    open()
    expect(screen.queryByText('Create profile')).toBeNull()
    await screen.findByLabelText(vmEn.cpu)
    expect(screen.queryByText('Create profile')).toBeNull()
    mocks.active = 'unrelated'
    await create()
    await waitFor(() => expect(mocks.api.mock.calls.some(([, request]) => request.method === 'POST')).toBe(true))
    expect(mocks.api.mock.calls.every(([owner]) => owner.connectionId === 'main' && owner.profile === 'default')).toBe(
      true
    )
    expect(mocks.api.mock.calls.find(([, request]) => request.method === 'POST')![1].body.resources).toEqual({
      cpu: 2,
      memory_mib: 2048,
      disk_gib: 20
    })
    fireEvent.click(screen.getByRole('button', { name: vmEn.createProfile }))
    expect(screen.getByText('Create profile')).toBeTruthy()
  }
)

it('keeps local creation hidden while capabilities resolve and on transient failure', async () => {
  let reject!: (reason: Error) => void
  mocks.api.mockImplementationOnce(
    () =>
      new Promise((_resolve, failure) => {
        reject = failure
      })
  )
  open()
  await waitFor(() => expect(mocks.api).toHaveBeenCalledTimes(1))
  expect(screen.queryByText('Create profile')).toBeNull()
  reject(new Error('503: unavailable'))
  await screen.findByRole('alert')
  expect(screen.queryByText('Create profile')).toBeNull()
})

it('preserves ordinary profile creation for an unsupported gateway but never falls back from a provisioned guest', async () => {
  mocks.api.mockRejectedValue(new Error('404: Not Found'))
  const view = open()
  await screen.findByText('Create profile')
  view.unmount()
  mocks.active = 'guest'
  open()
  await screen.findByRole('alert')
  expect(screen.queryByText('Create profile')).toBeNull()
})

it('refuses creation and registration after the captured main changes', async () => {
  mocks.active = 'guest'
  mocks.api.mockImplementation(async (_owner, request) =>
    request.path.endsWith('/capabilities')
      ? capabilities
      : {
          requests: [{ request_id: requestId, name: 'Existing', phase: 'ready' }]
        }
  )
  open()
  await screen.findByRole('button', { name: vmEn.connect })
  mocks.list.mockResolvedValue({ connections: [{ ...main, url: 'https://different.example' }, guest] })
  await create()
  await screen.findByText(vmEn.retrySame)
  fireEvent.click(screen.getByRole('button', { name: vmEn.connect }))
  await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/owner changed/))
  expect(mocks.register).not.toHaveBeenCalled()
  expect(mocks.api.mock.calls.some(([, request]) => request.method === 'POST')).toBe(false)
})
