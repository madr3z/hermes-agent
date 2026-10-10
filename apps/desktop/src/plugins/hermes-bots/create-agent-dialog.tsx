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

import { CreateAgentDialog, type CreateAgentDialogProps } from './create-dialog'
import { useBots } from './i18n'
import { VmCreate } from './vm-create'

export function CreateBotDialog(props: CreateAgentDialogProps) {
  const [vmMode, setVmMode] = useState(false)
  const b = useBots()

  if (!vmMode) {
    return <CreateAgentDialog {...props} onCreateVm={() => setVmMode(true)} />
  }

  return (
    <Dialog
      onOpenChange={value => {
        if (!value) {
          setVmMode(false)
          props.onClose()
        }
      }}
      open={props.open}
    >
      <DialogContent className="max-w-lg max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{b.vm.title}</DialogTitle>
          <DialogDescription>{b.vm.description}</DialogDescription>
        </DialogHeader>
        <VmCreate />
        <DialogFooter>
          <Button onClick={() => setVmMode(false)} variant="ghost">
            {b.vm.back}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
