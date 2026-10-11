interface TerminalSocket {
  readyState: number
  bufferedAmount: number
  send: (data: string | Uint8Array<ArrayBuffer>) => void
  close: (code: number) => void
}
export const MAX_TERMINAL_INPUT = 65536

export function sendTerminalInput(socket: TerminalSocket, bytes: Uint8Array): void {
  if (socket.readyState !== 1) {
    return
  }

  if (socket.bufferedAmount > 1024 * 1024 || bytes.length > 1024 * 1024) {
    socket.close(1000)

    return
  }

  for (let offset = 0; offset < bytes.length; offset += MAX_TERMINAL_INPUT) {
    socket.send(bytes.slice(offset, offset + MAX_TERMINAL_INPUT))
  }
}

export function sendTerminalResize(socket: TerminalSocket, cols: number, rows: number): void {
  if (socket.readyState !== 1) {
    return
  }

  socket.send(
    JSON.stringify({
      type: 'resize',
      cols: Math.min(500, Math.max(2, Math.floor(cols))),
      rows: Math.min(200, Math.max(2, Math.floor(rows)))
    })
  )
}
