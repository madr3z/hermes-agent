import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'

import { useVmPower } from './vm-power'
const mocks = vi.hoisted(() => ({ status: vi.fn(), power: vi.fn(), capabilities: vi.fn() }))
vi.mock('@hermes/plugin-sdk', () => ({
  host: { botVm: () => mocks },
  readKey: (key: string) => localStorage.getItem(key),
  writeKey: (key: string, value: string | null) =>
    value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value)
}))

const owner = {
  connectionId: 'main',
  requestId: 'vm-a',
  guestConnectionId: 'guest-a',
  mainUrl: 'https://main',
  guestUrl: 'https://main/vm-a'
}

const status = { request_id: 'vm-a', phase: 'running', observed_state: 'running', operation: null }
afterEach(() => {
  vi.clearAllMocks()
  vi.restoreAllMocks()
  localStorage.clear()
})
it('only sends power on explicit action and preserves the exact operation after a lost response', async () => {
  mocks.capabilities.mockResolvedValue({ vm_control: true })
  mocks.status.mockResolvedValue(status)
  mocks.power
    .mockRejectedValueOnce(new Error('response lost'))
    .mockImplementationOnce(async operation => ({ ...operation, request_id: 'vm-a', phase: 'accepted' }))
  const { result, unmount } = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(result.current.status).toEqual(status))
  expect(mocks.power).not.toHaveBeenCalled()
  await act(() => result.current.submit('restart'))
  expect(result.current.pending?.action).toBe('restart')
  await act(() => result.current.refresh())
  expect(mocks.power).toHaveBeenCalledTimes(1)
  await act(() => result.current.submit('restart'))
  expect(mocks.power.mock.calls[1][0]).toEqual(mocks.power.mock.calls[0][0])
  expect(result.current.pending).toBeNull()
  unmount()
  expect(mocks.power).toHaveBeenCalledTimes(2)
})
it('ignores stale status responses and does not issue commands on an older main server', async () => {
  mocks.capabilities.mockResolvedValue({})
  const { result, unmount } = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(result.current.supported).toBe(false))
  expect(mocks.status).not.toHaveBeenCalled()
  let older!: (value: unknown) => void
  mocks.status
    .mockImplementationOnce(
      () =>
        new Promise(resolve => {
          older = resolve
        })
    )
    .mockResolvedValueOnce({ ...status, phase: 'stopped' })
  let first!: Promise<void>
  act(() => {
    first = result.current.refresh()
  })
  await act(() => result.current.refresh())
  await act(async () => {
    older(status)
    await first
  })
  expect(result.current.status?.phase).toBe('stopped')
  expect(mocks.power).not.toHaveBeenCalled()
  unmount()
})

it('restores an unknown receipt with the same UUID and requires explicit state review before another command', async () => {
  const operation = { operation_id: crypto.randomUUID(), request_id: 'vm-a', action: 'restart', phase: 'unknown' }
  mocks.capabilities.mockResolvedValue({ vm_control: true })
  mocks.status.mockResolvedValue({ ...status, operation })
  mocks.power.mockResolvedValue(operation)
  const { result, unmount } = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(result.current.pending?.operation_id).toBe(operation.operation_id))
  await act(() => result.current.submit('restart'))
  expect(mocks.power).toHaveBeenCalledWith({ operation_id: operation.operation_id, action: 'restart' })
  expect(result.current.disabled).toBe(true)
  await act(() => result.current.recover())
  await act(() => result.current.refresh())
  expect(result.current.pending).toBeNull()
  expect(result.current.disabled).toBe(false)
  expect(mocks.power).toHaveBeenCalledTimes(1)
  unmount()
})

it('restores an uncertain POST across a pane remount and never generates another operation ID', async () => {
  mocks.capabilities.mockResolvedValue({ vm_control: true })
  mocks.status.mockResolvedValue(status)
  mocks.power
    .mockRejectedValueOnce(new Error('response lost'))
    .mockImplementationOnce(async operation => ({ ...operation, request_id: 'vm-a', phase: 'accepted' }))
  const first = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(first.result.current.status).toEqual(status))
  await act(() => first.result.current.submit('restart'))
  const operation = mocks.power.mock.calls[0][0]
  first.unmount()
  const second = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(second.result.current.status).toEqual(status))
  expect(second.result.current.pending).toEqual(operation)
  expect(mocks.power).toHaveBeenCalledTimes(1)
  await act(() => second.result.current.submit('restart'))
  expect(mocks.power.mock.calls[1][0]).toEqual(operation)
  expect(second.result.current.pending).toBeNull()
  second.unmount()
})

it('keeps Stop available during VM startup when no command is dispatching', async () => {
  mocks.capabilities.mockResolvedValue({ vm_control: true })
  mocks.status.mockResolvedValue({ ...status, phase: 'starting', desired_state: 'running' })
  const { result, unmount } = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(result.current.status?.phase).toBe('starting'))
  expect(result.current.disabled).toBe(false)
  expect(mocks.power).not.toHaveBeenCalled()
  unmount()
})

it('does not send a command when durable retry state cannot be stored', async () => {
  mocks.capabilities.mockResolvedValue({ vm_control: true })
  mocks.status.mockResolvedValue(status)
  const { result, unmount } = renderHook(() => useVmPower(owner))
  await waitFor(() => expect(result.current.status).toEqual(status))
  vi.spyOn(localStorage, 'setItem').mockImplementation(() => undefined)
  await act(() => result.current.submit('restart'))
  expect(mocks.power).not.toHaveBeenCalled()
  expect(result.current.storageFailed).toBe(true)
  unmount()
})
