import { hermesApiAs } from '@/api/client'
import { activeGatewayConnectionId } from '@/store/gateway'

import { botVmClient, resolveBotVmOwner } from './bot-vm'
import { vmDeletionClient } from './bot-vm-deletion'
import { listConnections } from './connections'

export interface BotVmRequest {
  request_id: string
  name: string
  linux_password: string
  resources: { cpu: number; memory_mib: number; disk_gib: number }
  credentials: { copy: boolean; source_profile: 'default' }
}
export interface BotVmStatus {
  request_id: string
  name: string
  phase: 'queued' | 'provisioning' | 'ready' | 'failed' | 'deleting' | 'deleted' | 'delete_failed'
  deletion_operation_id?: string
  error?: { code: string; message: string }
  gateway?: { id: string; label: string; base_url: string; profile: 'default' }
}
export interface BotVmCapabilities {
  available: boolean
  vm_control?: boolean
  vm_delete?: boolean
  linux_account?: {
    username: 'bot_name'
    username_pattern: string
    reserved_usernames: string[]
    password: { required: true; min_bytes: number; max_bytes: number }
  }
  resources: Record<'cpu' | 'memory_mib' | 'disk_gib', { min: number; max: number; default: number }>
  credential_keys: string[]
}

/** Capture native provenance once; every operation revalidates its owning main. */
export function botProvisioningClient() {
  const connectionId = activeGatewayConnectionId() || 'local'
  const prefix = '/api/plugins/bot-provisioning/v1'

  // Local profile creation remains immediate and needs no provisioning probe.
  const captured =
    connectionId === 'local'
      ? null
      : listConnections().then(rows => {
          const selected = rows.find(row => row.id === connectionId)

          if (!selected) {
            throw new Error('Provisioning connection was removed. Reopen Create Bot.')
          }

          const vm = selected.provisionedVm ? resolveBotVmOwner(rows, connectionId) : null

          if (selected.provisionedVm && !vm) {
            throw new Error('VM connection owner changed. Reopen Create Bot.')
          }

          return { selected, vm }
        })

  const owner = async () => {
    const snapshot = await captured

    if (!snapshot) {
      return { connectionId, profile: 'default' }
    }

    if (snapshot.vm) {
      await botVmClient(snapshot.vm).assertOwner()

      return { connectionId: snapshot.vm.connectionId, profile: 'default' }
    }

    const current = (await listConnections()).find(row => row.id === connectionId)

    if (
      !current ||
      current.kind !== snapshot.selected.kind ||
      current.url !== snapshot.selected.url ||
      current.authMode !== snapshot.selected.authMode ||
      current.provisionedVm
    ) {
      throw new Error('Provisioning connection changed. Reopen Create Bot.')
    }

    return { connectionId, profile: 'default' }
  }

  const request = async <T>(path: string, body?: unknown): Promise<T> =>
    hermesApiAs<T>(await owner(), { path, ...(body === undefined ? {} : { method: 'POST', body }) })

  return {
    connectionId,
    capabilities: async () => {
      try {
        return await request<BotVmCapabilities>(`${prefix}/capabilities`)
      } catch (error) {
        // A provisioned guest must never fall back to creating a profile in itself.
        if ((await captured)?.vm) {
          throw new Error('Main gateway provisioning is unavailable.')
        }

        throw error
      }
    },
    requestScope: async () => {
      const route = await owner()
      const snapshot = await captured

      return JSON.stringify({
        connectionId: route.connectionId,
        url: snapshot?.vm?.mainUrl ?? snapshot?.selected.url ?? ''
      })
    },
    status: (requestId: string) => request<BotVmStatus>(`${prefix}/requests/${encodeURIComponent(requestId)}`),
    list: () => request<{ requests: BotVmStatus[] }>(`${prefix}/requests`),
    create: (body: BotVmRequest) => request<BotVmStatus>(`${prefix}/requests`, body),
    deletion: (requestId: string) =>
      vmDeletionClient(
        requestId,
        request,
        async () => {
          const route = await owner()
          const snapshot = await captured

          return JSON.stringify({
            connectionId: route.connectionId,
            url: (snapshot?.vm?.mainUrl ?? snapshot?.selected.url ?? '').replace(/\/$/, '')
          })
        },
        async () => {
          const route = await owner()
          const rows = await listConnections()

          for (const row of rows) {
            const vm = resolveBotVmOwner(rows, row.id)

            if (vm?.connectionId === route.connectionId && vm.requestId === requestId) {
              await window.hermesDesktop.connections.remove(row.id)
            }
          }
        }
      ),
    register: async (requestId: string) =>
      window.hermesDesktop.connections.registerProvisioned({
        connectionId: (await owner()).connectionId,
        requestId
      })
  }
}
