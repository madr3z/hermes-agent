import type { host } from '@hermes/plugin-sdk'
import { type BotVmStatus } from '@hermes/plugin-sdk'
import { useEffect, useRef, useState } from 'react'

import { useBots } from './i18n'
import { type PendingVmCreate, persistPendingCreate, readPendingCreate } from './vm-create-pending'

type Client = ReturnType<typeof host.botProvisioning>

async function lookup(client: Client, requestId: string): Promise<BotVmStatus | null> {
  try {
    return await client.status(requestId)
  } catch (error) {
    if (error instanceof Error && /\b404:/.test(error.message)) {
      return null
    }

    throw error
  }
}

export function useVmCreationRequest(
  client: Client,
  restore: (request: PendingVmCreate) => void,
  accepted: (result: BotVmStatus) => void
) {
  const b = useBots().vm
  const [scope, setScope] = useState<string | null>(null)
  const [pending, setPending] = useState<PendingVmCreate | null>(null)
  const [needsPassword, setNeedsPassword] = useState(false)
  const [ready, setReady] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const secret = useRef('')
  const flight = useRef(false)

  // eslint-disable-next-line no-restricted-syntax -- Clear the transient password on unmount; no reactive state is mirrored.
  useEffect(() => {
    let active = true

    void (async () => {
      try {
        const owner = await client.requestScope()
        const saved = readPendingCreate(owner)

        if (!active) {
          return
        }

        setScope(owner)

        if (saved) {
          setPending(saved)
          restore(saved)
          const receipt = await lookup(client, saved.request_id)

          if (!active) {
            return
          }

          if (receipt) {
            persistPendingCreate(owner, null)
            setPending(null)
            accepted(receipt)
          } else {
            setNeedsPassword(true)
            setError(b.resumePassword)
          }
        }
      } catch {
        if (active) {
          setError(b.retrySame)
        }
      } finally {
        if (active) {
          setReady(true)
        }
      }
    })()

    return () => {
      active = false
      secret.current = ''
    }
  }, [client, restore, accepted, b.resumePassword, b.retrySame])

  const submit = async (draft: Omit<PendingVmCreate, 'request_id'>, password: string, canSend: boolean) => {
    if (flight.current || !scope || !ready) {
      return
    }

    flight.current = true
    setBusy(true)
    setError('')

    try {
      const request = pending ?? { ...draft, request_id: crypto.randomUUID() }
      const receipt = pending ? await lookup(client, request.request_id) : null

      if (!receipt && !canSend) {
        setNeedsPassword(true)
        setError(b.resumePassword)

        return
      }

      if (!receipt) {
        try {
          persistPendingCreate(scope, request)
        } catch {
          setError(b.storageFailed)

          return
        }

        setPending(request)
        setNeedsPassword(false)
        secret.current ||= password
      }

      const result = receipt ?? (await client.create({ ...request, linux_password: secret.current }))

      secret.current = ''
      persistPendingCreate(scope, null)
      setPending(null)
      setNeedsPassword(false)
      accepted(result)
    } catch {
      setError(b.retrySame)
    } finally {
      flight.current = false
      setBusy(false)
    }
  }

  return { submit, pending, needsPassword, ready: ready && scope !== null, busy, error }
}
