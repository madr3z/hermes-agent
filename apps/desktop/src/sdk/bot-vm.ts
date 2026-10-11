import { hermesApiAs } from '@/api/client'
import { resolveSiblingWsUrl } from '@/lib/sibling-ws-url'
import { $connectionsRegistry } from '@/store/connection-registry-state'

import type { BotVmCapabilities } from './bot-provisioning'
import { listConnections } from './connections'

export interface BotVmOwner {
  connectionId: string
  requestId: string
  guestConnectionId: string
  mainUrl: string
  guestUrl: string
}
export type VmPowerAction = 'start' | 'stop' | 'restart'
export interface VmPowerOperation {
  operation_id: string
  request_id: string
  action: VmPowerAction
  phase: 'queued' | 'dispatching' | 'accepted' | 'unknown' | 'failed'
  error?: { code: string; message: string }
}
export interface VmRuntimeStatus {
  request_id: string
  desired_state: 'running' | 'stopped' | 'unknown'
  observed_state: 'running' | 'stopped' | 'pending' | 'failed' | 'unknown'
  phase: 'running' | 'starting' | 'stopping' | 'stopped' | 'failed' | 'unknown'
  ready: boolean
  error?: { code: string; message: string }
  resources: { cpu: number; memory_mib: number; disk_gib: number }
  operation: VmPowerOperation | null
}
interface VmConnection {
  id: string
  kind: string
  url?: string
  authMode?: string
  provisionedVm?: { connectionId: string; requestId: string }
}

/** Provenance is written by native registration; an edited or removed owner is not a VM route. */
export function resolveBotVmOwner(rows: VmConnection[], guestConnectionId: string): BotVmOwner | null {
  const guest = rows.find(row => row.id === guestConnectionId)
  const vm = guest?.provisionedVm
  const main = rows.find(row => row.id === vm?.connectionId)

  if (!vm || !main?.url || guest?.kind !== 'remote' || main.kind !== 'remote' || main.authMode === 'oauth') {
    return null
  }

  const mainUrl = main.url.replace(/\/$/, '')
  const guestUrl = `${mainUrl}/api/plugins/bot-provisioning/v1/gateways/${vm.requestId}`

  if (!URL.canParse(mainUrl)) {
    return null
  }

  const base = new URL(mainUrl)

  if (
    base.protocol !== 'https:' ||
    base.username ||
    base.password ||
    base.search ||
    base.hash ||
    guest.url !== guestUrl
  ) {
    return null
  }

  return { ...vm, guestConnectionId, mainUrl, guestUrl }
}

export function hasBotVm(connectionId?: string): boolean {
  return !!connectionId && !!resolveBotVmOwner($connectionsRegistry.get()?.connections ?? [], connectionId)
}

export async function botVmOwner(connectionId: string): Promise<BotVmOwner | null> {
  return resolveBotVmOwner(await listConnections(), connectionId)
}

/** Every call verifies the captured owner again. Active gateway selection never changes the target. */
export function botVmClient(owner: BotVmOwner) {
  const prefix = `/api/plugins/bot-provisioning/v1/requests/${owner.requestId}`

  const check = async () => {
    const current = await botVmOwner(owner.guestConnectionId)

    if (
      !current ||
      current.connectionId !== owner.connectionId ||
      current.requestId !== owner.requestId ||
      current.mainUrl !== owner.mainUrl ||
      current.guestUrl !== owner.guestUrl
    ) {
      throw new Error('VM connection owner changed. Reopen the VM pane.')
    }
  }

  const main = async <T>(path: string, body?: unknown): Promise<T> => {
    await check()

    return hermesApiAs<T>(
      { connectionId: owner.connectionId, profile: 'default' },
      {
        path,
        ...(body === undefined ? {} : { method: 'POST', body })
      }
    )
  }

  return {
    assertOwner: check,
    capabilities: () => main<BotVmCapabilities>('/api/plugins/bot-provisioning/v1/capabilities'),
    status: () => main<VmRuntimeStatus>(`${prefix}/vm`),
    power: (operation: { operation_id: string; action: VmPowerAction }) =>
      main<VmPowerOperation>(`${prefix}/power`, operation),
    operation: (id: string) => main<VmPowerOperation>(`${prefix}/power/${encodeURIComponent(id)}`),
    terminalStatus: async () => {
      await check()

      try {
        return await hermesApiAs<{ available: boolean; protocol: string; max_input_bytes: number }>(
          { connectionId: owner.guestConnectionId, profile: 'default' },
          { path: '/api/terminal/status' }
        )
      } catch (error) {
        if (error instanceof Error && /\b404:/.test(error.message)) {
          return { available: false, protocol: 'hermes-terminal-v1', max_input_bytes: 65536 }
        }

        throw error
      }
    },
    terminalUrl: async () => {
      await check()

      const url = new URL(
        await resolveSiblingWsUrl({ connectionId: owner.guestConnectionId, profile: 'default' }, '/api/terminal/ws')
      )

      const expected = new URL(owner.guestUrl + '/api/terminal/ws')

      if (url.protocol !== 'wss:' || url.host !== expected.host || url.pathname !== expected.pathname) {
        throw new Error('VM connection owner changed. Reopen the VM pane.')
      }

      return url.toString()
    }
  }
}
