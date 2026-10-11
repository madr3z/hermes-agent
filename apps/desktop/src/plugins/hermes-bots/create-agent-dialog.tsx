import {
  type BotVmCapabilities,
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  host
} from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

import { CreateAgentDialog, type CreateAgentDialogProps } from './create-dialog'
import { useBots } from './i18n'
import { VmCreate } from './vm-create'

export function CreateBotDialog(props: CreateAgentDialogProps) {
  return props.open ? <CreateBotSession {...props} /> : null
}

function CreateBotSession(props: CreateAgentDialogProps) {
  const [client] = useState(() => host.botProvisioning())
  const [mode, setMode] = useState(client.connectionId === 'local' ? 'profile' : 'checking')
  const [capabilities, setCapabilities] = useState<BotVmCapabilities | undefined>()
  const b = useBots()

  useEffect(() => {
    if (mode !== 'checking') {
      return
    }

    let active = true

    void client
      .capabilities()
      .then(result => {
        if (active) {
          setCapabilities(result)
          setMode('vm')
        }
      })
      .catch(error => {
        if (active) {
          setMode(error instanceof Error && /\b404:/.test(error.message) ? 'profile' : 'unavailable')
        }
      })

    return () => {
      active = false
    }
  }, [client, mode])

  if (mode === 'profile') {
    return <CreateAgentDialog {...props} onCreateVm={() => setMode('vm')} />
  }

  return (
    <Dialog
      onOpenChange={value => {
        if (!value) {props.onClose()}
      }}
      open={props.open}
    >
      <DialogContent className="max-w-lg max-h-[85vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>{b.vm.title}</DialogTitle>
          <DialogDescription>{b.vm.description}</DialogDescription>
        </DialogHeader>
        {mode === 'checking' ? <p role="status">{b.vm.connecting}</p> : null}
        {mode === 'unavailable' ? (
          <>
            <p role="alert">{b.vm.unavailable}</p>
            <Button onClick={() => setMode('checking')}>{b.vm.refresh}</Button>
          </>
        ) : null}
        {mode === 'vm' ? <VmCreate client={client} initialCapabilities={capabilities} /> : null}
        {mode !== 'checking' ? (
          <DialogFooter>
            <Button onClick={() => setMode('profile')} variant="ghost">
              {b.vm.createProfile}
            </Button>
          </DialogFooter>
        ) : null}
      </DialogContent>
    </Dialog>
  )
}
