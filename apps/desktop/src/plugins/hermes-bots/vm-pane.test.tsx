import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, expect, it, vi } from 'vitest'

import { vmEn } from './vm-i18n'
import { VmPane } from './vm-pane'
const mocks = vi.hoisted(() => ({ submit: vi.fn(), refresh: vi.fn(), screenMounts: 0, terminalMounts: 0 }))
vi.mock('@hermes/plugin-sdk', async () => {
  const React = await import('react')

  return {
    Button: ({
      variant: _variant,
      size: _size,
      ...props
    }: ComponentProps<'button'> & { variant?: string; size?: string }) => <button {...props} />,
    ConfirmDialog: () => null,
    RemoteVmTerminal: () => {
      React.useEffect(() => {
        mocks.terminalMounts++
      }, [])

      return <div data-testid="terminal" />
    }
  }
})
vi.mock('./screen-pane', async () => {
  const React = await import('react')

  return {
    BotScreenPane: () => {
      React.useEffect(() => {
        mocks.screenMounts++
      }, [])

      return <div data-testid="screen" />
    }
  }
})
vi.mock('./i18n', () => ({ useBots: () => ({ vm: vmEn }) }))
vi.mock('./vm-power', () => ({
  useVmPower: () => ({
    status: {
      phase: 'failed',
      desired_state: 'running',
      observed_state: 'failed',
      resources: { cpu: 2, memory_mib: 2048, disk_gib: 20 }
    },
    supported: true,
    disabled: false,
    submit: mocks.submit,
    refresh: mocks.refresh
  })
}))
afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  mocks.screenMounts = 0
  mocks.terminalMounts = 0
})
it('permits Stop for a failed running VM, and hiding or closing its surfaces never issues power commands', () => {
  const { unmount } = render(
    <VmPane
      bot={{ name: 'default' }}
      name="Research"
      owner={{
        connectionId: 'main',
        requestId: 'vm',
        guestConnectionId: 'guest',
        mainUrl: 'https://main',
        guestUrl: 'https://main/vm'
      }}
    />
  )

  expect((screen.getByRole('button', { name: 'Stop' }) as HTMLButtonElement).disabled).toBe(false)
  expect((screen.getByRole('button', { name: 'Start' }) as HTMLButtonElement).disabled).toBe(true)
  expect((screen.getByRole('button', { name: 'Restart' }) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('tab', { name: 'Terminal' }))
  fireEvent.click(screen.getByRole('tab', { name: 'Screen' }))
  fireEvent.click(screen.getByRole('tab', { name: 'Terminal' }))
  expect(mocks.screenMounts).toBe(1)
  expect(mocks.terminalMounts).toBe(1)
  unmount()
  expect(mocks.submit).not.toHaveBeenCalled()
})
