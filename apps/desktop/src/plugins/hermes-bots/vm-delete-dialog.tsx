import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@hermes/plugin-sdk'
import { useState } from 'react'

import { useBots } from './i18n'
import { useVmDeletion, type VmDeletionClient } from './vm-delete-request'

export function VmDeleteDialog({
  client: suppliedClient,
  onClose,
  onDeleted
}: {
  client: VmDeletionClient
  onClose: () => void
  onDeleted: () => Promise<void>
}) {
  // The confirmation stays bound to the request captured when this dialog opened.
  const [client] = useState(() => suppliedClient)
  const [accepted] = useState(() => onDeleted)
  const b = useBots().vm
  const deletion = useVmDeletion(client, accepted)
  const waiting = deletion.receipt && ['queued', 'deleting'].includes(deletion.receipt.phase)

  return (
    <Dialog
      onOpenChange={open => {
        if (!open) {onClose()}
      }}
      open
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{b.deleteTitle.replace('{name}', deletion.name)}</DialogTitle>
          <DialogDescription>{b.deleteDescription.replace('{name}', deletion.name)}</DialogDescription>
        </DialogHeader>
        {!deletion.ready && !deletion.error ? <p role="status">{b.checkingOwner}</p> : null}
        {waiting ? <p role="status">{b.deleting}</p> : null}
        {deletion.receipt?.phase === 'failed' ? (
          <p role="alert">{deletion.receipt.error?.message || b.deleteFailed}</p>
        ) : null}
        {deletion.error ? <p role="alert">{deletion.error}</p> : null}
        <DialogFooter>
          <Button onClick={onClose} variant="ghost">
            {b.close}
          </Button>
          <Button
            disabled={!deletion.ready || deletion.busy || !!waiting}
            onClick={() => void deletion.submit()}
            variant="destructive"
          >
            {deletion.pending ? b.retryDelete : b.deleteAction}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
