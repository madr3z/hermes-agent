import { type BotVmOwner, Button, ConfirmDialog, RemoteVmTerminal, type VmPowerAction } from '@hermes/plugin-sdk'
import { useState } from 'react'

import { useBots } from './i18n'
import { BotScreenPane } from './screen-pane'
import type { RosterRow } from './types'
import { useVmPower } from './vm-power'

interface VmPaneProps {
  owner: BotVmOwner
  bot: RosterRow
  name: string
}

export function VmPane({ owner, bot, name }: VmPaneProps) {
  const b = useBots().vm
  const power = useVmPower(owner)
  const [tab, setTab] = useState<'screen' | 'terminal'>('screen')
  const [terminalOpened, setTerminalOpened] = useState(false)
  const [confirm, setConfirm] = useState<Exclude<VmPowerAction, 'start'> | 'recover' | null>(null)

  return (
    <div className="flex h-full min-h-0 flex-col gap-3 p-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-medium">{name}</span>
        <span className="text-xs text-(--ui-text-secondary)" role="status">
          {power.supported === false ? b.controlUnavailable : power.status ? b[power.status.phase] : b.connecting}
        </span>
        <Button
          disabled={power.disabled || power.status?.phase !== 'stopped'}
          onClick={() => void power.submit('start')}
          size="sm"
          variant="secondary"
        >
          {b.start}
        </Button>
        <Button
          disabled={power.disabled || power.status?.desired_state !== 'running'}
          onClick={() => setConfirm('stop')}
          size="sm"
          variant="secondary"
        >
          {b.stop}
        </Button>
        <Button
          disabled={power.disabled || power.status?.phase !== 'running'}
          onClick={() => setConfirm('restart')}
          size="sm"
          variant="secondary"
        >
          {b.restart}
        </Button>
        <Button disabled={power.busy} onClick={() => void power.refresh()} size="sm" variant="ghost">
          {b.refresh}
        </Button>
      </div>
      {power.status && (
        <p className="text-xs text-(--ui-text-tertiary)">
          {b.resources}: {power.status.resources.cpu} {b.cpu} · {power.status.resources.memory_mib} {b.memory_mib} ·{' '}
          {power.status.resources.disk_gib} {b.disk_gib}
        </p>
      )}
      <VmPowerFeedback onRecover={() => setConfirm('recover')} power={power} />
      <div aria-label={b.remoteTitle} className="flex gap-2" role="tablist">
        <Button
          aria-selected={tab === 'screen'}
          onClick={() => setTab('screen')}
          role="tab"
          size="sm"
          variant={tab === 'screen' ? 'secondary' : 'ghost'}
        >
          {b.screen}
        </Button>
        <Button
          aria-selected={tab === 'terminal'}
          onClick={() => {
            setTerminalOpened(true)
            setTab('terminal')
          }}
          role="tab"
          size="sm"
          variant={tab === 'terminal' ? 'secondary' : 'ghost'}
        >
          {b.terminal}
        </Button>
      </div>
      <div className="min-h-0 flex-1" hidden={tab !== 'screen'}>
        <BotScreenPane bot={bot} />
      </div>
      {terminalOpened && (
        <div className="min-h-0 flex-1" hidden={tab !== 'terminal'}>
          <RemoteVmTerminal
            labels={{
              connecting: b.connecting,
              connected: b.connected,
              disconnected: b.disconnected,
              superseded: b.superseded,
              exited: b.exited,
              unsupported: b.terminalUnavailable,
              reconnect: b.reconnect
            }}
            owner={owner}
            visible={tab === 'terminal'}
          />
        </div>
      )}
      <p className="text-xs text-(--ui-text-tertiary)">{b.persistent}</p>
      <ConfirmDialog
        confirmLabel={confirm === 'recover' ? b.recover : confirm === 'stop' ? b.stop : b.restart}
        description={confirm === 'recover' ? b.recoverConfirm : b.powerConfirm}
        destructive
        dismissOnConfirm
        onClose={() => setConfirm(null)}
        onConfirm={async () => {
          if (confirm === 'recover') {
            await power.recover()
          } else if (confirm) {
            await power.submit(confirm)
          }
        }}
        open={confirm !== null}
        title={`${confirm === 'recover' ? b.recover : confirm === 'stop' ? b.stop : b.restart} · ${name}`}
      />
    </div>
  )
}

function VmPowerFeedback({ power, onRecover }: { power: ReturnType<typeof useVmPower>; onRecover: () => void }) {
  const b = useBots().vm
  const operation = power.status?.operation ?? power.receipt

  return (
    <>
      {power.error && (
        <p className="text-xs text-(--ui-text-secondary)" role="alert">
          {power.pending ? b.powerUnknown : power.storageFailed ? b.storageFailed : b.connectionFailed}
        </p>
      )}
      {power.pending && (
        <Button
          disabled={power.busy}
          onClick={() => void power.submit(power.pending!.action)}
          size="sm"
          variant="secondary"
        >
          {b.retryPower}
        </Button>
      )}
      {power.pending && operation?.phase === 'unknown' && (
        <Button disabled={power.busy} onClick={onRecover} size="sm" variant="secondary">
          {b.recover}
        </Button>
      )}
      {operation && (
        <p className="text-xs text-(--ui-text-secondary)">
          {b.operation}: {b[operation.action]} · {b[`operation_${operation.phase}`]}
          {operation.error ? ` · ${operation.error.message}` : ''}
        </p>
      )}
    </>
  )
}
