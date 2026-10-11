import {
  type BotVmCapabilities,
  type BotVmRequest,
  type BotVmStatus,
  Button,
  Checkbox,
  host,
  Input
} from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'

import { useBots } from './i18n'

/** The durable request belongs to the captured main gateway, not this dialog's lifetime. */
interface VmCreateProps {
  client?: ReturnType<typeof host.botProvisioning>
  initialCapabilities?: BotVmCapabilities
}

export function VmCreate({ client: suppliedClient, initialCapabilities }: VmCreateProps = {}) {
  const b = useBots().vm
  const [client] = useState(() => suppliedClient ?? host.botProvisioning())
  const [capabilities, setCapabilities] = useState<BotVmCapabilities | null>(null)
  const [requests, setRequests] = useState<BotVmStatus[]>([])
  const [name, setName] = useState('')
  const [resources, setResources] = useState({ cpu: 2, memory_mib: 2048, disk_gib: 20 })
  const [copy, setCopy] = useState(false)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const pending = useRef<BotVmRequest | null>(null)
  const flight = useRef(false)
  useEffect(() => {
    let active = true
    let timer: ReturnType<typeof setTimeout>

    const refresh = async () => {
      try {
        const result = await client.list()

        if (active) {
          setRequests(result.requests)
        }
      } catch {
        if (active) {
          setError(b.unavailable)
        }
      } finally {
        if (active) {
          timer = setTimeout(refresh, 5000)
        }
      }
    }

    void (initialCapabilities ? Promise.resolve(initialCapabilities) : client.capabilities())
      .then(result => {
        if (!active) {
          return
        }

        setCapabilities(result)

        if (!result.available) {
          setError(b.unavailable)

          return
        }

        setResources({
          cpu: result.resources.cpu.default,
          memory_mib: result.resources.memory_mib.default,
          disk_gib: result.resources.disk_gib.default
        })
        void refresh()
      })
      .catch(() => {
        if (active) {
          setError(b.unavailable)
        }
      })

    return () => {
      active = false
      clearTimeout(timer)
    }
  }, [client, b.unavailable, initialCapabilities])

  const create = async () => {
    if (flight.current) {
      return
    }

    flight.current = true
    setBusy(true)
    setError('')
    // Keep the exact payload and UUID on an ambiguous transport failure.
    pending.current ??= {
      request_id: crypto.randomUUID(),
      name,
      resources,
      credentials: { copy, source_profile: 'default' }
    }

    try {
      const result = await client.create(pending.current)
      setRequests(rows => [result, ...rows.filter(row => row.request_id !== result.request_id)])
      pending.current = null
      setName('')
    } catch {
      setError(b.retrySame)
    } finally {
      flight.current = false
      setBusy(false)
    }
  }

  const register = async (id: string) => {
    setError('')

    try {
      await client.register(id)
      host.notify({ kind: 'success', message: b.registered })
    } catch (err) {
      setError(err instanceof Error ? err.message : b.unavailable)
    }
  }

  const valid =
    /^[a-z0-9][a-z0-9-]{0,47}$/.test(name) &&
    capabilities &&
    Object.entries(resources).every(([key, value]) => {
      const bounds = capabilities.resources[key as keyof typeof resources]

      return Number.isInteger(value) && value >= bounds.min && value <= bounds.max
    })

  return (
    <div className="grid gap-3">
      <p className="text-xs text-(--ui-text-secondary)">{b.description}</p>
      <label className="grid gap-1 text-xs">
        {b.name}
        <Input disabled={busy || !!pending.current} onChange={event => setName(event.target.value)} value={name} />
      </label>
      <div className="grid grid-cols-3 gap-2">
        {(['cpu', 'memory_mib', 'disk_gib'] as const).map(key => (
          <label className="grid gap-1 text-xs" key={key}>
            {b[key]}
            <Input
              disabled={busy || !!pending.current}
              max={capabilities?.resources[key].max}
              min={capabilities?.resources[key].min}
              onChange={event => setResources(previous => ({ ...previous, [key]: Number(event.target.value) }))}
              type="number"
              value={resources[key]}
            />
          </label>
        ))}
      </div>
      <label className="flex items-center gap-2 text-xs">
        <Checkbox
          checked={copy}
          disabled={busy || !!pending.current}
          onCheckedChange={value => setCopy(value === true)}
        />
        {b.copy}
      </label>
      <p className="text-xs text-(--ui-text-secondary)">{b.exclusions}</p>
      {copy && capabilities ? <p className="text-xs">{capabilities.credential_keys.join(', ')}</p> : null}
      <Button disabled={busy || !capabilities?.available || (!valid && !pending.current)} onClick={() => void create()}>
        {pending.current ? b.retry : b.create}
      </Button>
      {error ? (
        <p className="text-xs text-(--ui-accent)" role="alert">
          {error}
        </p>
      ) : null}
      <div aria-live="polite" className="grid gap-2">
        {requests.map(row => (
          <div className="rounded border p-2 text-xs" key={row.request_id}>
            <div>
              {row.name} — {b[row.phase]}
            </div>
            <div className="text-(--ui-text-tertiary)">{row.request_id}</div>
            {row.error ? <p>{row.error.message}</p> : null}
            {row.phase === 'ready' ? (
              <Button onClick={() => void register(row.request_id)} size="sm">
                {b.connect}
              </Button>
            ) : null}
          </div>
        ))}
      </div>
    </div>
  )
}
