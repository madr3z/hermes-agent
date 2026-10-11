import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'

import { VmCreate } from './vm-create'
import { vmEn } from './vm-i18n'
import { validVmLogin } from './vm-login-validation'
const mocks = vi.hoisted(() => ({ create: vi.fn(), register: vi.fn(), list: vi.fn(), status: vi.fn() }))
vi.mock('@hermes/plugin-sdk', () => ({
  Button: (props: ComponentProps<'button'>) => <button {...props} />,
  Input: (props: ComponentProps<'input'>) => <input {...props} />,
  Checkbox: ({
    onCheckedChange,
    ...props
  }: ComponentProps<'input'> & { onCheckedChange: (value: boolean) => void }) => (
    <input {...props} onChange={event => onCheckedChange(event.target.checked)} type="checkbox" />
  ),
  readKey: (key: string) => localStorage.getItem(key),
  writeKey: (key: string, value: string | null) =>
    value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value),
  host: {
    notify: vi.fn(),
    botProvisioning: () => ({
      ...mocks,
      requestScope: async () => 'main-scope',
      capabilities: async () => ({
        available: true,
        linux_account: {
          username: 'bot_name',
          username_pattern: '^[a-z][a-z0-9_-]{0,31}$',
          reserved_usernames: ['root'],
          password: { required: true, min_bytes: 8, max_bytes: 256 }
        },
        resources: {
          cpu: { min: 1, max: 4, default: 2 },
          memory_mib: { min: 2048, max: 4096, default: 2048 },
          disk_gib: { min: 20, max: 40, default: 20 }
        },
        credential_keys: ['OPENAI_API_KEY']
      })
    })
  }
}))
vi.mock('./i18n', () => ({ useBots: () => ({ vm: vmEn }) }))
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  localStorage.clear()
})
it('reuses the UUID and body after an ambiguous submission and defaults credential copy off', async () => {
  mocks.list.mockResolvedValue({ requests: [] })
  mocks.create
    .mockRejectedValueOnce(new Error('connection lost'))
    .mockImplementationOnce(async body => ({ ...body, phase: 'queued' }))
  render(<VmCreate />)
  fireEvent.change(screen.getByLabelText(vmEn.name), { target: { value: 'research' } })
  enterPassword('chosen-password')
  await waitFor(() => expect((screen.getByText('Create VM') as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByText('Create VM'))
  await screen.findByText(vmEn.retrySame)
  expect(JSON.stringify(localStorage)).not.toContain('chosen-password')
  fireEvent.click(screen.getByText('Retry same request'))
  await waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(2))
  const first = mocks.create.mock.calls[0][0]
  expect(mocks.status).toHaveBeenCalledWith(first.request_id)
  expect(mocks.status.mock.invocationCallOrder[0]).toBeLessThan(mocks.create.mock.invocationCallOrder[1])
  expect(first.linux_password).toBe('chosen-password')
  expect(screen.getByLabelText(vmEn.password)).toHaveProperty('value', '')
  expect(localStorage.length).toBe(0)
  expect(first.credentials.copy).toBe(false)
  expect(first.resources).toEqual({ cpu: 2, memory_mib: 2048, disk_gib: 20 })
  expect(mocks.create.mock.calls[1][0]).toEqual(first)
})
it('restores server status on reopen and registers only a ready gateway', async () => {
  mocks.list.mockResolvedValue({
    requests: [
      { request_id: 'ready-id', name: 'Existing', phase: 'ready' },
      { request_id: 'pending-id', name: 'Waiting', phase: 'provisioning' }
    ]
  })
  mocks.register.mockResolvedValue({})
  render(<VmCreate />)
  const button = await screen.findByText('Add gateway')
  expect(screen.getAllByText('Add gateway')).toHaveLength(1)
  fireEvent.click(button)
  await waitFor(() => expect(mocks.register).toHaveBeenCalledWith('ready-id'))
})

const policy = {
  username: 'bot_name' as const,
  username_pattern: '^[a-z][a-z0-9_-]{0,31}$',
  reserved_usernames: ['root'],
  password: { required: true as const, min_bytes: 8, max_bytes: 256 }
}

beforeEach(() => {
  mocks.status.mockRejectedValue(new Error('404: Not Found'))
  mocks.list.mockResolvedValue({ requests: [] })
})

function enterPassword(password: string, confirmation = password) {
  fireEvent.change(screen.getByLabelText(vmEn.password), { target: { value: password } })
  fireEvent.change(screen.getByLabelText(vmEn.confirmPassword), { target: { value: confirmation } })
}

it('requires an exact valid bot login and matching byte-bounded passwords before submission', async () => {
  mocks.create.mockRejectedValue(new Error('response lost'))
  render(<VmCreate />)
  const name = screen.getByLabelText(vmEn.name)
  const button = screen.getByRole('button', { name: vmEn.create })
  fireEvent.change(name, { target: { value: 'root' } })
  enterPassword('chosen-password')
  await waitFor(() => expect(button).toHaveProperty('disabled', true))

  for (const invalid of ['Research', '1research', 'r'.repeat(33)]) {
    fireEvent.change(name, { target: { value: invalid } })
    expect(button).toHaveProperty('disabled', true)
  }

  fireEvent.change(name, { target: { value: 'research_team' } })
  expect(screen.getByLabelText(vmEn.username)).toHaveProperty('value', 'research_team')
  expect(screen.getByLabelText(vmEn.username)).toHaveProperty('readOnly', true)
  expect(screen.getByLabelText(vmEn.password)).toHaveProperty('type', 'password')
  enterPassword('chosen-password', 'different-password')
  expect(button).toHaveProperty('disabled', true)
  enterPassword('🔒')
  expect(button).toHaveProperty('disabled', true)
  enterPassword('é'.repeat(129))
  expect(button).toHaveProperty('disabled', true)

  for (const invalid of ['abcdefgh\0', 'abcdefgh\r', 'abcdefgh\n']) {
    expect(validVmLogin('research_team', invalid, invalid, policy)).toBe(false)
  }

  expect(validVmLogin('research_team', 'é'.repeat(128), 'é'.repeat(128), policy)).toBe(true)
  enterPassword('🔒🔒')
  await waitFor(() => expect(button).toHaveProperty('disabled', false))
  fireEvent.click(button)
  await waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(1))
  expect(mocks.create.mock.calls[0][0]).toMatchObject({ name: 'research_team', linux_password: '🔒🔒' })
  expect(mocks.create.mock.calls[0][0]).not.toHaveProperty('confirmation')

  const stored = Array.from({ length: localStorage.length }, (_, index) =>
    localStorage.getItem(localStorage.key(index)!)
  ).join('')

  expect(stored).toContain('research_team')
  expect(stored).not.toContain('linux_password')
  expect(stored).not.toContain('🔒')
})

it.each(['found', 'missing'])(
  'looks up the saved request before any password reentry or retry after memory loss: %s',
  async outcome => {
    mocks.create.mockRejectedValueOnce(new Error('response lost'))
    const first = render(<VmCreate />)
    fireEvent.change(screen.getByLabelText(vmEn.name), { target: { value: 'research' } })
    enterPassword('chosen-password')
    await waitFor(() => expect(screen.getByRole('button', { name: vmEn.create })).toHaveProperty('disabled', false))
    fireEvent.click(screen.getByRole('button', { name: vmEn.create }))
    await screen.findByText(vmEn.retrySame)
    const original = mocks.create.mock.calls[0][0]
    first.unmount()
    let resolve!: (value: unknown) => void
    let reject!: (error: Error) => void
    mocks.status.mockImplementationOnce(
      () =>
        new Promise((success, failure) => {
          resolve = success
          reject = failure
        })
    )
    render(<VmCreate />)
    await waitFor(() => expect(mocks.status).toHaveBeenCalledWith(original.request_id))
    expect(screen.getByLabelText(vmEn.password)).toHaveProperty('disabled', true)
    expect(screen.getByLabelText(vmEn.password)).toHaveProperty('value', '')
    expect(mocks.create).toHaveBeenCalledTimes(1)

    if (outcome === 'found') {
      resolve({ request_id: original.request_id, name: original.name, phase: 'queued' })
      await waitFor(() => expect(localStorage.length).toBe(0))
      expect(mocks.create).toHaveBeenCalledTimes(1)
    } else {
      reject(new Error('404: Not Found'))
      await screen.findByText(vmEn.resumePassword)
      expect(screen.getByLabelText(vmEn.password)).toHaveProperty('disabled', false)
      mocks.create.mockImplementationOnce(async body => ({
        request_id: body.request_id,
        name: body.name,
        phase: 'queued'
      }))
      enterPassword('chosen-password')
      fireEvent.click(screen.getByRole('button', { name: vmEn.retry }))
      await waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(2))
      expect(mocks.create.mock.calls[1][0]).toEqual(original)
      expect(mocks.status.mock.invocationCallOrder[1]).toBeLessThan(mocks.create.mock.invocationCallOrder[1])
      expect(localStorage.length).toBe(0)
    }

    expect(screen.getByLabelText(vmEn.password)).toHaveProperty('value', '')
  }
)

const fixedCapabilities = {
  available: true,
  linux_account: policy,
  resources: {
    cpu: { min: 1, max: 2, default: 2 },
    memory_mib: { min: 2560, max: 2560, default: 2560 },
    disk_gib: { min: 20, max: 20, default: 20 }
  },
  credential_keys: []
}

it('explains each blocked input and uses the main gateway fixed RAM and disk defaults', async () => {
  const client = {
    ...mocks,
    deletion: vi.fn(),
    connectionId: 'main',
    requestScope: async () => 'main-scope',
    capabilities: async () => fixedCapabilities
  }

  render(<VmCreate client={client} initialCapabilities={fixedCapabilities} />)
  const button = screen.getByRole('button', { name: vmEn.create })
  await screen.findByText(vmEn.nameRequired)
  expect(screen.getByLabelText(vmEn.memory_mib)).toHaveProperty('value', '2560')
  expect(button).toHaveProperty('disabled', true)
  fireEvent.change(screen.getByLabelText(vmEn.name), { target: { value: 'Hermes Test' } })
  expect(screen.getByText(vmEn.invalidUsername)).toBeTruthy()
  fireEvent.change(screen.getByLabelText(vmEn.name), { target: { value: 'hermes-test' } })
  expect(screen.getByText(vmEn.passwordRequired)).toBeTruthy()
  enterPassword('short')
  expect(screen.getByText(vmEn.passwordLength.replace('{min}', '8').replace('{max}', '256'))).toBeTruthy()
  enterPassword('test-password', '')
  expect(screen.getByText(vmEn.confirmationRequired)).toBeTruthy()
  enterPassword('test-password', 'different')
  expect(screen.getByText(vmEn.passwordMismatch)).toBeTruthy()
  enterPassword('test-password')
  expect(button).toHaveProperty('disabled', false)
  fireEvent.change(screen.getByLabelText(vmEn.memory_mib), { target: { value: '2048' } })
  expect(
    screen.getByText(
      vmEn.resourceBounds.replace('{resource}', vmEn.memory_mib).replace('{min}', '2560').replace('{max}', '2560')
    )
  ).toBeTruthy()
  expect(button).toHaveProperty('disabled', true)
  fireEvent.change(screen.getByLabelText(vmEn.memory_mib), { target: { value: '2560' } })
  expect(button).toHaveProperty('disabled', false)
  expect(mocks.create).not.toHaveBeenCalled()
})

it('explains a failed captured-owner check and never enables creation against another gateway', async () => {
  const client = {
    ...mocks,
    deletion: vi.fn(),
    connectionId: 'main',
    requestScope: async () => {
      throw new Error('owner changed')
    },
    capabilities: async () => fixedCapabilities
  }

  render(<VmCreate client={client} />)
  await screen.findByText(vmEn.ownerUnavailable)
  expect(screen.getByRole('button', { name: vmEn.create })).toHaveProperty('disabled', true)
  expect(screen.getByLabelText(vmEn.password)).toHaveProperty('disabled', true)
  expect(mocks.create).not.toHaveBeenCalled()
})
