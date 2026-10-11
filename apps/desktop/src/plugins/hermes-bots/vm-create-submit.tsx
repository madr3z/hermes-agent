import { Button } from '@hermes/plugin-sdk'
import { useId } from 'react'

import { useBots } from './i18n'
import type { PendingVmCreate } from './vm-create-pending'
import type { useVmCreationRequest } from './vm-create-request'

interface VmCreateSubmitProps {
  creation: ReturnType<typeof useVmCreationRequest>
  problem: string | null
  password: string
  draft: Omit<PendingVmCreate, 'request_id'>
}

export function VmCreateSubmit({ creation, problem, password, draft }: VmCreateSubmitProps) {
  const b = useBots().vm
  const reasonId = useId()
  const { busy, pending } = creation
  const valid = problem === null

  const blockedReason = busy
    ? b.submitting
    : !creation.ready
      ? creation.error || b.checkingOwner
      : pending && !creation.needsPassword
        ? null
        : problem

  return (
    <>
      {blockedReason ? (
        <p className="text-xs" id={reasonId} role="status">
          {blockedReason}
        </p>
      ) : null}
      <Button
        aria-describedby={blockedReason ? reasonId : undefined}
        disabled={busy || !creation.ready || (!valid && (!pending || creation.needsPassword))}
        onClick={() => void creation.submit(draft, password, valid)}
      >
        {pending ? b.retry : b.create}
      </Button>
    </>
  )
}
