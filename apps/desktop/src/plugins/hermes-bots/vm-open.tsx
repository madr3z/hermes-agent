import { ContextMenuItem, host } from '@hermes/plugin-sdk'

import { botsText, useBots } from './i18n'
import { displayName } from './labels'
import { botScreenRoute } from './screen-connection'
import type { BotMeta, RosterRow } from './types'
import { VmPane } from './vm-pane'

const open = new Set<string>()

export async function openBotVm(bot: RosterRow, meta?: BotMeta | null): Promise<void> {
  try {
    const route = botScreenRoute(bot)

    if (!route || typeof route === 'string') {
      host.notify({ kind: 'info', message: botsText().vm.controlUnavailable })

      return
    }

    const owner = await host.botVmOwner(route.connectionId)

    if (!owner) {
      host.notify({ kind: 'info', message: botsText().vm.controlUnavailable })

      return
    }

    const id = `hermes-bots:vm:${owner.guestConnectionId}`

    if (open.has(id)) {
      host.revealPane(`plugin-workspace:${id}`)

      return
    }

    // A VM is a machine, independent of a profile selected in its roster.
    const guest = {
      ...bot,
      name: 'default',
      vmOwner: owner,
      route: { ...route, profile: 'default', targetProfile: 'default' }
    } as RosterRow

    const name = bot.connectionLabel || displayName(bot, meta ?? null)
    host.openWorkspace(id, {
      title: `${name} · ${botsText().vm.remoteTitle}`,
      minWidth: '28rem',
      render: () => <VmPane bot={guest} name={name} owner={owner} />,
      onClose: () => {
        open.delete(id)
      }
    })
    open.add(id)
  } catch {
    host.notify({ kind: 'error', message: botsText().vm.connectionFailed })
  }
}

export function VmMenuItem({ bot, meta }: { bot: RosterRow; meta?: BotMeta | null }) {
  const b = useBots().vm

  if (!host.hasBotVm?.(bot.route?.connectionId ?? bot.connectionId)) {
    return null
  }

  return <ContextMenuItem onSelect={() => void openBotVm(bot, meta)}>{b.remoteTitle}</ContextMenuItem>
}
