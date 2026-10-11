import {
  type BotVmOwner,
  host,
  type VmPowerAction,
  type VmPowerOperation,
  type VmRuntimeStatus
} from '@hermes/plugin-sdk'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { persistPendingPower, readPendingPower } from './vm-power-persistence'

export function useVmPower(owner: BotVmOwner) {
  const client = useMemo(() => host.botVm(owner), [owner])
  const [status, setStatus] = useState<VmRuntimeStatus | null>(null)
  const [supported, setSupported] = useState<boolean | null>(null)
  const [receipt, setReceipt] = useState<VmPowerOperation | null>(null)
  const [pending, setPending] = useState(() => readPendingPower(owner))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(false)
  const [storageFailed, setStorageFailed] = useState(false)
  const alive = useRef(false)
  const generation = useRef(0)
  const flight = useRef(false)
  const acknowledged = useRef<string | null>(null)

  const refresh = useCallback(async () => {
    const current = ++generation.current

    try {
      const next = await client.status()

      if (alive.current && generation.current === current) {
        setStatus(next)
        const saved = readPendingPower(owner)

        if (
          saved &&
          next.operation &&
          saved.operation_id === next.operation.operation_id &&
          ['accepted', 'failed'].includes(next.operation.phase)
        ) {
          persistPendingPower(owner, null)
          setPending(null)
        }

        if (next.operation?.phase === 'unknown' && acknowledged.current !== next.operation.operation_id) {
          const operation = { operation_id: next.operation.operation_id, action: next.operation.action }
          persistPendingPower(owner, operation)
          setPending(operation)
        }

        setError(false)
      }
    } catch {
      if (alive.current && generation.current === current) {
        setError(true)
      }
    }
  }, [client, owner])

  // Lifetime and request generations are guards, not mirrored render state.
  // eslint-disable-next-line no-restricted-syntax
  useEffect(() => {
    alive.current = true
    let active = true
    let timer: ReturnType<typeof setTimeout>

    const poll = async () => {
      await refresh()

      if (active) {
        timer = setTimeout(poll, 3000)
      }
    }

    void client
      .capabilities()
      .then(capabilities => {
        if (!active) {
          return
        }

        setSupported(capabilities.vm_control === true)

        if (capabilities.vm_control) {
          void poll()
        }
      })
      .catch(() => {
        if (active) {
          setError(true)
        }
      })

    return () => {
      active = false
      alive.current = false
      // This is an async request epoch, not a DOM ref.
      // eslint-disable-next-line react-hooks/exhaustive-deps
      generation.current++
      clearTimeout(timer)
    }
  }, [client, refresh])

  const submit = async (action: VmPowerAction) => {
    if (flight.current) {
      return
    }

    flight.current = true
    setBusy(true)
    setStorageFailed(false)
    let sent = false
    const operation = pending ?? { operation_id: crypto.randomUUID(), action }

    try {
      persistPendingPower(owner, operation)
      setPending(operation)
      sent = true
      const result = await client.power(operation)

      if (!alive.current) {
        return
      }

      setReceipt(result)
      const unresolved = !['accepted', 'failed'].includes(result.phase)
      persistPendingPower(owner, unresolved ? operation : null)
      setPending(unresolved ? operation : null)
      await refresh()
    } catch {
      // A transport error is not a rejected command. Preserve the UUID/body.
      if (alive.current) {
        setStorageFailed(!sent)
        setError(true)
      }
    } finally {
      flight.current = false

      if (alive.current) {
        setBusy(false)
      }
    }
  }

  const recover = async () => {
    const current = ++generation.current
    const next = await client.status()

    if (!alive.current || generation.current !== current) {
      return
    }

    setStatus(next)
    setError(false)
    acknowledged.current = pending?.operation_id ?? null
    persistPendingPower(owner, null)
    setPending(null)
  }

  const currentOperation = status?.operation ?? receipt

  const transitioning = currentOperation?.phase === 'queued' || currentOperation?.phase === 'dispatching'

  return {
    status,
    supported,
    storageFailed,
    receipt,
    pending,
    busy,
    error,
    refresh,
    submit,
    recover,
    disabled: !supported || !status || busy || !!pending || !!transitioning || error
  }
}
