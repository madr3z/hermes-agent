import { type BotVmOwner, ContextMenuItem, ContextMenuSeparator, host, useI18n } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

import { isDefaultBot } from './data'
import { useBots } from './i18n'
import { botScreenRoute } from './screen-connection'
import type { RosterRow } from './types'

type Target = { connectionId: string; kind: 'profile' } | { connectionId: string; kind: 'vm'; owner: BotVmOwner }

/** This is the roster's single delete action; managed rows never fall back to profile removal. */
export function VmDeleteMenuItem({ bot, onDelete }: { bot: RosterRow; onDelete: (bot: RosterRow) => void }) {
  const b = useBots().vm
  const { t } = useI18n()
  const route = botScreenRoute(bot)
  const connectionId = typeof route === 'string' ? 'local' : route?.connectionId
  const [target, setTarget] = useState<Target | null>(null)
  useEffect(() => {
    let active = true

    if (!connectionId || connectionId === 'local') {return}
    void (async () => {
      try {
        const entry = (await host.connections()).find(row => row.id === connectionId)

        if (!entry) {return}

        if (!entry.provisionedVm) {
          if (active) {setTarget({ connectionId, kind: 'profile' })}

          return
        }

        const owner = await host.botVmOwner(connectionId)

        if (owner && (await host.botVm(owner).capabilities()).vm_delete && active)
          {setTarget({ connectionId, kind: 'vm', owner })}
      } catch {
        /* Unverified ownership cannot authorize either deletion path. */
      }
    })()

    return () => {
      active = false
    }
  }, [connectionId])
  const current = target?.connectionId === connectionId ? target : null
  const profileOnly = connectionId === 'local' || current?.kind === 'profile'

  if (current?.kind === 'vm')
    {return (
      <>
        <ContextMenuSeparator />
        <ContextMenuItem onSelect={() => onDelete({ ...bot, vmOwner: current.owner })} variant="destructive">
          {b.deleteAction}
        </ContextMenuItem>
      </>
    )}

  return profileOnly && !isDefaultBot(bot) ? (
    <>
      <ContextMenuSeparator />
      <ContextMenuItem onSelect={() => onDelete(bot)} variant="destructive">
        {t.common.delete}
      </ContextMenuItem>
    </>
  ) : null
}
