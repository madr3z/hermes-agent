import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, expect, it, vi } from 'vitest'

import { VmDeleteDialog } from './vm-delete-dialog'
import type { VmDeletionClient } from './vm-delete-request'
import { vmEn } from './vm-i18n'

vi.mock('@hermes/plugin-sdk', () => ({
  readKey: (key: string) => localStorage.getItem(key),
  writeKey: (key: string, value: string | null) =>
    value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value),
  Button: ({ variant: _variant, ...props }: ComponentProps<'button'> & { variant?: string }) => <button {...props} />,
  Dialog: ({ children }: ComponentProps<'div'>) => <div>{children}</div>,
  DialogContent: ({ children }: ComponentProps<'div'>) => <div>{children}</div>,
  DialogDescription: ({ children }: ComponentProps<'div'>) => <p>{children}</p>,
  DialogFooter: ({ children }: ComponentProps<'div'>) => <div>{children}</div>,
  DialogHeader: ({ children }: ComponentProps<'div'>) => <div>{children}</div>,
  DialogTitle: ({ children }: ComponentProps<'div'>) => <h2>{children}</h2>
}))
vi.mock('./i18n', () => ({ useBots: () => ({ vm: vmEn }) }))
afterEach(() => {
  cleanup()
  localStorage.clear()
})
const requestId = '25d2e87a-80d9-41e2-a154-5fbbfae2bf70'

function fixture() {
  return {
    requestId,
    scope: vi.fn(async () => 'captured-main-request'),
    capabilities: vi.fn(async () => ({ available: true, vm_delete: true })),
    status: vi.fn(async () => ({ request_id: requestId, name: 'hermes-test', phase: 'ready' })),
    operation: vi.fn(),
    submit: vi.fn(),
    forget: vi.fn(async () => undefined)
  }
}

it('confirms VM and file removal, retains its UUID across uncertain retry and reopen, and forgets only after deleted', async () => {
  const client = fixture()
  const onDeleted = vi.fn(async () => undefined)
  client.submit.mockRejectedValueOnce(new Error('response lost'))

  const first = render(
    <VmDeleteDialog client={client as unknown as VmDeletionClient} onClose={() => undefined} onDeleted={onDeleted} />
  )

  await waitFor(() => expect(screen.getByText(vmEn.deleteAction)).toHaveProperty('disabled', false))
  expect(screen.getByText(vmEn.deleteDescription.replace('{name}', 'hermes-test'))).toBeTruthy()
  expect(client.submit).not.toHaveBeenCalled()
  fireEvent.click(screen.getByText(vmEn.deleteAction))
  await screen.findByText(vmEn.deleteRetrySame)
  const body = client.submit.mock.calls[0][0]
  expect(body.confirm_name).toBe('hermes-test')
  expect(localStorage.length).toBe(1)
  client.operation.mockRejectedValueOnce(new Error('404: not found'))
  client.submit.mockResolvedValueOnce({
    operation_id: body.operation_id,
    request_id: requestId,
    action: 'delete',
    phase: 'queued'
  })
  fireEvent.click(screen.getByText(vmEn.retryDelete))
  await screen.findByText(vmEn.deleting)
  expect(client.submit.mock.calls[1][0]).toEqual(body)
  expect(client.operation.mock.invocationCallOrder[0]).toBeLessThan(client.submit.mock.invocationCallOrder[1])
  expect(client.forget).not.toHaveBeenCalled()
  first.unmount()
  client.status.mockResolvedValueOnce({
    request_id: requestId,
    name: 'hermes-test',
    phase: 'deleting',
    deletion_operation_id: body.operation_id
  } as never)
  let phase = 'deleting'
  client.operation.mockImplementation(async () => ({
    operation_id: body.operation_id,
    request_id: requestId,
    action: 'delete',
    phase
  }))
  render(
    <VmDeleteDialog client={client as unknown as VmDeletionClient} onClose={() => undefined} onDeleted={onDeleted} />
  )
  await screen.findByText(vmEn.deleting)
  expect(client.submit).toHaveBeenCalledTimes(2)
  expect(client.forget).not.toHaveBeenCalled()
  phase = 'deleted'
  await waitFor(() => expect(client.forget).toHaveBeenCalledWith(body.operation_id), { timeout: 5000 })
  expect(onDeleted).toHaveBeenCalledTimes(1)
  expect(localStorage.length).toBe(0)
})

it('blocks POST on a non-404 recovery failure and requires an explicit fresh UUID after a failed operation', async () => {
  const client = fixture()
  client.submit.mockRejectedValueOnce(new Error('response lost'))

  const props = {
    client: client as unknown as VmDeletionClient,
    onClose: () => undefined,
    onDeleted: async () => undefined
  }

  const first = render(<VmDeleteDialog {...props} />)
  await waitFor(() => expect(screen.getByText(vmEn.deleteAction)).toHaveProperty('disabled', false))
  fireEvent.click(screen.getByText(vmEn.deleteAction))
  await screen.findByText(vmEn.deleteRetrySame)
  const original = client.submit.mock.calls[0][0]
  first.unmount()
  client.operation.mockRejectedValueOnce(new Error('503: unavailable'))
  const second = render(<VmDeleteDialog {...props} />)
  await screen.findByText(vmEn.deleteLookupFailed)
  expect(screen.getByText(vmEn.retryDelete)).toHaveProperty('disabled', true)
  expect(client.submit).toHaveBeenCalledTimes(1)
  second.unmount()
  client.operation.mockResolvedValue({
    operation_id: original.operation_id,
    request_id: requestId,
    action: 'delete',
    phase: 'failed'
  })
  client.submit.mockResolvedValueOnce({ operation_id: 'new', request_id: requestId, action: 'delete', phase: 'queued' })
  render(<VmDeleteDialog {...props} />)
  await waitFor(() => expect(screen.getByText(vmEn.retryDelete)).toHaveProperty('disabled', false))
  expect(client.submit).toHaveBeenCalledTimes(1)
  fireEvent.click(screen.getByText(vmEn.retryDelete))
  await waitFor(() => expect(client.submit).toHaveBeenCalledTimes(2))
  expect(client.submit.mock.calls[1][0].operation_id).not.toBe(original.operation_id)
  expect(client.submit.mock.calls[1][0].confirm_name).toBe(original.confirm_name)
  expect(client.forget).not.toHaveBeenCalled()
})
