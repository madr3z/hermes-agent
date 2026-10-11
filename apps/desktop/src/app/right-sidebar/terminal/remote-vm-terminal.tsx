import '@xterm/xterm/css/xterm.css'

import { useStore } from '@nanostores/react'
import { FitAddon } from '@xterm/addon-fit'
import { Terminal } from '@xterm/xterm'
import { useEffect, useRef, useState } from 'react'

import { Button } from '@/components/ui/button'
import { botVmClient, type BotVmOwner } from '@/sdk/bot-vm'
import { useTheme } from '@/themes/context'

import { sendTerminalInput, sendTerminalResize } from './remote-vm-transport'
import { terminalTheme } from './selection'
import { $terminalFontFamily, resolveTerminalFontFamily } from './terminal-font'

export interface RemoteVmTerminalProps {
  owner: BotVmOwner
  visible: boolean
  labels: Record<
    'connecting' | 'connected' | 'disconnected' | 'superseded' | 'exited' | 'unsupported' | 'reconnect',
    string
  >
}
type TerminalState = Exclude<keyof RemoteVmTerminalProps['labels'], 'reconnect'>

/** Guest tmux owns the shell. This component only attaches; it never launches a local PTY. */
export function RemoteVmTerminal({ owner, visible, labels }: RemoteVmTerminalProps) {
  const element = useRef<HTMLDivElement>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [state, setState] = useState<TerminalState>('connecting')
  const font = resolveTerminalFontFamily(useStore($terminalFontFamily))
  const { renderedMode, theme } = useTheme()
  const palette = renderedMode === 'dark' ? (theme.darkTerminal ?? theme.terminal) : theme.terminal

  useEffect(() => {
    if (termRef.current) {
      termRef.current.options.theme = terminalTheme(renderedMode, palette)
      termRef.current.options.fontFamily = font

      if (visible) {
        fitRef.current?.fit()
      }
    }
  }, [font, palette, renderedMode, visible])

  // These refs own the mounted terminal resource, not mirrored reactive state.
  // eslint-disable-next-line no-restricted-syntax
  useEffect(() => {
    let active = true
    let socket: WebSocket | null = null

    const term = new Terminal({
      cursorBlink: true,
      scrollback: 2000,
      fontFamily: font,
      theme: terminalTheme(renderedMode, palette),
      allowProposedApi: false
    })

    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(element.current!)
    termRef.current = term
    fitRef.current = fit
    fit.fit()
    setState('connecting')

    const observer = new ResizeObserver(() => {
      if (element.current?.clientWidth && element.current.clientHeight) {
        fit.fit()
      }
    })

    observer.observe(element.current!)

    const data = term.onData(value => {
      if (socket) {
        sendTerminalInput(socket, new TextEncoder().encode(value))
      }
    })

    const binary = term.onBinary(value => {
      if (socket) {
        sendTerminalInput(
          socket,
          Uint8Array.from(value, char => char.charCodeAt(0))
        )
      }
    })

    const resize = term.onResize(({ cols, rows }) => {
      if (socket) {
        sendTerminalResize(socket, cols, rows)
      }
    })

    const attach = async () => {
      try {
        const client = botVmClient(owner)
        const status = await client.terminalStatus()

        if (!active) {
          return
        }

        if (!status.available || status.protocol !== 'hermes-terminal-v1') {
          setState('unsupported')

          return
        }

        const url = await client.terminalUrl()

        if (!active) {
          return
        }

        socket = new WebSocket(url)
        socket.binaryType = 'arraybuffer'

        socket.onopen = () => {
          if (!active) {
            return
          }

          setState('connected')
          fit.fit()
          sendTerminalResize(socket!, term.cols, term.rows)
        }

        socket.onmessage = event => {
          if (active && event.data instanceof ArrayBuffer) {
            term.write(new Uint8Array(event.data))
          }
        }

        socket.onclose = event => {
          if (active) {
            setState(event.code === 4409 ? 'superseded' : event.code === 4410 ? 'exited' : 'disconnected')
          }
        }

        socket.onerror = () => {
          if (active) {
            setState('disconnected')
          }
        }
      } catch {
        if (active) {
          setState('disconnected')
        }
      }
    }

    void attach()

    return () => {
      active = false
      socket?.close(1000)
      observer.disconnect()
      data.dispose()
      binary.dispose()
      resize.dispose()
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
    // A theme or visibility change must not detach/reclaim the persistent shell.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [attempt, owner])

  return (
    <div className="flex h-full min-h-0 flex-col gap-2" data-terminal="">
      <div className="flex items-center gap-2 text-xs text-(--ui-text-secondary)" role="status">
        <span>{labels[state]}</span>
        {state !== 'connected' && state !== 'connecting' && state !== 'unsupported' && (
          <Button onClick={() => setAttempt(value => value + 1)} size="sm" variant="secondary">
            {labels.reconnect}
          </Button>
        )}
      </div>
      <div className="min-h-0 flex-1" ref={element} />
    </div>
  )
}
