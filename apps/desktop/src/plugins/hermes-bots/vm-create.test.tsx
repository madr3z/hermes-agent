import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, expect, it, vi } from 'vitest'

import { VmCreate } from './vm-create'
const mocks = vi.hoisted(() => ({ create: vi.fn(), register: vi.fn(), list: vi.fn() }))
vi.mock('@hermes/plugin-sdk', () => ({
  Button: (props: ComponentProps<'button'>) => <button {...props} />,
  Input: (props: ComponentProps<'input'>) => <input {...props} />,
  Checkbox: ({
    onCheckedChange,
    ...props
  }: ComponentProps<'input'> & { onCheckedChange: (value: boolean) => void }) => (
    <input {...props} onChange={event => onCheckedChange(event.target.checked)} type="checkbox" />
  ),
  host: {
    notify: vi.fn(),
    botProvisioning: () => ({
      ...mocks,
      capabilities: async () => ({
        available: true,
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
vi.mock('./i18n', () => ({
  useBots: () => ({
    vm: {
      name: 'Name',
      cpu: 'CPU',
      memory_mib: 'RAM',
      disk_gib: 'Disk',
      copy: 'Copy keys',
      create: 'Create VM',
      retry: 'Retry same request',
      unavailable: 'Unavailable',
      retrySame: 'Retry safely',
      ready: 'Ready',
      connect: 'Add gateway'
    }
  })
}))
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})
it('reuses the UUID and body after an ambiguous submission and defaults credential copy off', async () => {
  mocks.list.mockResolvedValue({ requests: [] })
  mocks.create
    .mockRejectedValueOnce(new Error('connection lost'))
    .mockImplementationOnce(async body => ({ ...body, phase: 'queued' }))
  render(<VmCreate />)
  fireEvent.change(screen.getByLabelText('Name'), { target: { value: 'research' } })
  await waitFor(() => expect((screen.getByText('Create VM') as HTMLButtonElement).disabled).toBe(false))
  fireEvent.click(screen.getByText('Create VM'))
  await screen.findByText('Retry safely')
  fireEvent.click(screen.getByText('Retry same request'))
  await waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(2))
  const first = mocks.create.mock.calls[0][0]
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
