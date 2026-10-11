import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'

import { RemoteVmTerminal } from './remote-vm-terminal'

const mocks = vi.hoisted(() => ({
  input: null as null | ((value: string) => void),
  write: vi.fn(),
  fit: vi.fn(),
  status: vi.fn()
}))

vi.mock('@xterm/xterm', () => ({
  Terminal: class {
    cols = 80
    rows = 24
    options = {}
    open() {}
    loadAddon() {}
    dispose() {}
    write = mocks.write
    onData(fn: (value: string) => void) {
      mocks.input = fn

      return { dispose() {} }
    }
    onBinary() {
      return { dispose() {} }
    }
    onResize() {
      return { dispose() {} }
    }
  }
}))
vi.mock('@xterm/addon-fit', () => ({
  FitAddon: class {
    fit = mocks.fit
  }
}))
vi.mock('@/sdk/bot-vm', () => ({
  botVmClient: () => ({
    terminalStatus: mocks.status,
    terminalUrl: async () => 'wss://main.example/selected-vm/api/terminal/ws?token=main-token'
  })
}))
vi.mock('@/themes/context', () => ({ useTheme: () => ({ renderedMode: 'dark', theme: {} }) }))

class Socket {
  static instances: Socket[] = []
  readyState = 0
  bufferedAmount = 0
  binaryType = ''
  send = vi.fn()
  close = vi.fn()
  onopen?: () => void
  onclose?: (event: { code: number }) => void
  onmessage?: (event: { data: ArrayBuffer }) => void
  onerror?: () => void
  constructor(readonly url: string) {
    Socket.instances.push(this)
  }
}

const owner = {
  connectionId: 'main',
  requestId: 'vm-a',
  guestConnectionId: 'guest-a',
  mainUrl: 'https://main',
  guestUrl: 'https://main/vm-a'
}

const labels = {
  connecting: 'Connecting',
  connected: 'Connected',
  disconnected: 'Disconnected',
  superseded: 'Other client',
  exited: 'Exited',
  unsupported: 'Unavailable',
  reconnect: 'Reconnect'
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
  Socket.instances = []
})
it('sends initial dimensions on open, preserves attachment when hidden, and never fights an evicting client', async () => {
  mocks.status.mockResolvedValue({ available: true, protocol: 'hermes-terminal-v1' })
  vi.stubGlobal('WebSocket', Socket)
  vi.stubGlobal(
    'ResizeObserver',
    class {
      observe() {}
      disconnect() {}
    }
  )
  const { rerender, unmount } = render(<RemoteVmTerminal labels={labels} owner={owner} visible />)
  await waitFor(() => expect(Socket.instances).toHaveLength(1))
  const socket = Socket.instances[0]
  act(() => {
    socket.readyState = 1
    socket.onopen?.()
  })
  expect(socket.send).toHaveBeenCalledWith(JSON.stringify({ type: 'resize', cols: 80, rows: 24 }))
  act(() => {
    mocks.input?.('echo π\r')
    socket.onmessage?.({ data: new Uint8Array([27, 91, 50, 74]).buffer })
  })
  expect(socket.send.mock.calls[1][0]).toEqual(new TextEncoder().encode('echo π\r'))
  expect(mocks.write).toHaveBeenCalledWith(new Uint8Array([27, 91, 50, 74]))
  rerender(<RemoteVmTerminal labels={labels} owner={owner} visible={false} />)
  expect(Socket.instances).toHaveLength(1)
  expect(socket.close).not.toHaveBeenCalled()
  act(() => {
    socket.onclose?.({ code: 4409 })
  })
  expect(screen.getByText('Other client')).toBeTruthy()
  expect(Socket.instances).toHaveLength(1)
  fireEvent.click(screen.getByText('Reconnect'))
  await waitFor(() => expect(Socket.instances).toHaveLength(2))
  unmount()
  expect(Socket.instances[1].close).toHaveBeenCalledWith(1000)
})
