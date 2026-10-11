// @vitest-environment node

import type { EventEmitter } from 'node:events'
import { once } from 'node:events'
import { createRequire } from 'node:module'

import { afterEach, expect, it } from 'vitest'
interface FixtureSocket extends EventEmitter {
  readyState: number
  bufferedAmount: number
  send(data: string | Uint8Array): void
  close(code: number): void
  terminate(): void
}
interface FixtureServer extends EventEmitter {
  address(): { port: number } | string | null
  close(done: () => void): void
}

const { WebSocket, WebSocketServer } = createRequire(import.meta.url)('ws') as {
  WebSocket: new (url: string) => FixtureSocket
  WebSocketServer: new (options: { port: number; host: string }) => FixtureServer
}

import { sendTerminalInput, sendTerminalResize } from './remote-vm-transport'
const sockets: FixtureSocket[] = []
let server: FixtureServer | undefined
afterEach(async () => {
  for (const socket of sockets) {
    socket.terminate()
  }

  sockets.length = 0

  if (server) {
    await new Promise<void>(resolve => server!.close(() => resolve()))
  }
})
it('sends raw UTF-8 input as bounded binary frames and bounded JSON resize over a real WebSocket', async () => {
  server = new WebSocketServer({ port: 0, host: '127.0.0.1' })
  await once(server, 'listening')
  const address = server.address()

  if (typeof address !== 'object' || !address) {
    throw new Error('Missing fixture address')
  }

  const accepted = once(server, 'connection')
  const client = new WebSocket(`ws://127.0.0.1:${address.port}/api/terminal/ws`)
  const [peer] = (await accepted) as [FixtureSocket]
  sockets.push(client, peer)
  await once(client, 'open')
  const frames: { binary: boolean; bytes: Buffer }[] = []
  peer.on('message', (bytes: Buffer, binary: boolean) => frames.push({ bytes: Buffer.from(bytes as Buffer), binary }))
  const bytes = new TextEncoder().encode('π'.repeat(40000))
  sendTerminalInput(client, bytes)
  sendTerminalResize(client, 999, 1)
  await new Promise<void>(resolve => {
    const wait = () => (frames.length === 3 ? resolve() : setTimeout(wait, 5))
    wait()
  })
  expect(frames.slice(0, 2).map(frame => frame.binary)).toEqual([true, true])
  expect(frames[0].bytes.length).toBe(65536)
  expect(Buffer.concat(frames.slice(0, 2).map(frame => frame.bytes))).toEqual(Buffer.from(bytes))
  expect(frames[2].binary).toBe(false)
  expect(JSON.parse(frames[2].bytes.toString())).toEqual({ type: 'resize', cols: 500, rows: 2 })
})
