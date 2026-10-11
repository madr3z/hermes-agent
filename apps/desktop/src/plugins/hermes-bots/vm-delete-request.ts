import { type host, readKey, writeKey } from '@hermes/plugin-sdk'
import { useCallback, useEffect, useRef, useState } from 'react'

import { useBots } from './i18n'

export type VmDeletionClient = ReturnType<ReturnType<typeof host.botProvisioning>['deletion']>
type VmDeleteOperation = Awaited<ReturnType<VmDeletionClient['operation']>>
type VmDeleteSubmission = Parameters<VmDeletionClient['submit']>[0]
const storageKey = (scope: string) => `hermes-desktop-vm-delete-v1:${encodeURIComponent(scope)}`

function readPending(scope: string): VmDeleteSubmission | null {
  try {
    const raw = readKey(storageKey(scope))

    if (!raw) {
      return null
    }

    const value = JSON.parse(raw) as VmDeleteSubmission

    return /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.operation_id) &&
      typeof value.confirm_name === 'string'
      ? { operation_id: value.operation_id, confirm_name: value.confirm_name }
      : null
  } catch {
    return null
  }
}

function persist(scope: string, pending: VmDeleteSubmission | null) {
  const value = pending
    ? JSON.stringify({ operation_id: pending.operation_id, confirm_name: pending.confirm_name })
    : null

  writeKey(storageKey(scope), value)

  if (pending && readKey(storageKey(scope)) !== value) {
    throw new Error('Cannot save the deletion operation.')
  }
}

async function lookup(client: VmDeletionClient, id: string) {
  try {
    return await client.operation(id)
  } catch (error) {
    if (error instanceof Error && /\b404:/.test(error.message)) {
      return null
    }

    throw error
  }
}

export function useVmDeletion(client: VmDeletionClient, accepted: () => Promise<void>) {
  const b = useBots().vm
  const [scope, setScope] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [pending, setPending] = useState<VmDeleteSubmission | null>(null)
  const [receipt, setReceipt] = useState<VmDeleteOperation | null>(null)
  const [ready, setReady] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const flight = useRef(false)

  const apply = useCallback(
    async (value: VmDeleteOperation, ownerScope: string) => {
      setReceipt(value)

      if (value.phase === 'deleted') {
        await client.forget(value.operation_id)
        persist(ownerScope, null)
        setPending(null)
        await accepted()
      }
    },
    [client, accepted]
  )

  useEffect(() => {
    let active = true

    void (async () => {
      try {
        const [ownerScope, capabilities, status] = await Promise.all([
          client.scope(),
          client.capabilities(),
          client.status()
        ])

        if (!active) {
          return
        }

        if (!capabilities.vm_delete) {
          setError(b.deleteUnavailable)

          return
        }

        setScope(ownerScope)
        setName(status.name)
        const saved = readPending(ownerScope)

        const operation = status.deletion_operation_id
          ? { operation_id: status.deletion_operation_id, confirm_name: status.name }
          : saved

        if (operation) {
          if (operation.confirm_name !== status.name) {
            setError(b.deleteUnavailable)

            return
          }

          persist(ownerScope, operation)
          setPending(operation)
          const found = await lookup(client, operation.operation_id)

          if (!active) {
            return
          }

          if (found) {
            await apply(found, ownerScope)
          }
        }

        if (active) {
          setReady(true)
        }
      } catch {
        if (active) {
          setError(b.deleteLookupFailed)
        }
      }
    })()

    return () => {
      active = false
    }
  }, [client, apply, b.deleteUnavailable, b.deleteLookupFailed])

  const phase = receipt?.phase
  useEffect(() => {
    if (!scope || !pending || !phase || !['queued', 'deleting'].includes(phase)) {
      return
    }

    let active = true
    let timer: ReturnType<typeof setTimeout>

    const refresh = async () => {
      try {
        const found = await client.operation(pending.operation_id)

        if (active) {
          setError('')
          await apply(found, scope)
        }
      } catch {
        if (active) {
          setError(b.deleteLookupFailed)
        }
      }

      if (active) {
        timer = setTimeout(refresh, 2000)
      }
    }

    timer = setTimeout(refresh, 2000)

    return () => {
      active = false
      clearTimeout(timer)
    }
  }, [client, apply, scope, pending, phase, b.deleteLookupFailed])

  const submit = async () => {
    if (!ready || !scope || flight.current) {
      return
    }

    flight.current = true
    setBusy(true)
    setError('')

    try {
      if (!(await client.capabilities()).vm_delete) {
        setError(b.deleteUnavailable)

        return
      }

      let operation = pending

      if (operation) {
        const found = await lookup(client, operation.operation_id)

        if (found && found.phase !== 'failed') {
          await apply(found, scope)

          return
        }

        if (found?.phase === 'failed') {
          operation = null
        }
      }

      operation ??= { operation_id: crypto.randomUUID(), confirm_name: name }

      try {
        persist(scope, operation)
      } catch {
        setError(b.storageFailed)

        return
      }

      setPending(operation)
      await apply(await client.submit(operation), scope)
    } catch {
      setError(b.deleteRetrySame)
    } finally {
      flight.current = false
      setBusy(false)
    }
  }

  return { name, pending, receipt, ready, busy, error, submit }
}
