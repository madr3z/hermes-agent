import { hermesApiAs } from '@/api/client'
import { activeGatewayConnectionId } from '@/store/gateway'

export interface BotVmRequest {
  request_id: string
  name: string
  resources: { cpu: number; memory_mib: number; disk_gib: number }
  credentials: { copy: boolean; source_profile: 'default' }
}
export interface BotVmStatus {
  request_id: string
  name: string
  phase: 'queued' | 'provisioning' | 'ready' | 'failed'
  error?: { code: string; message: string }
  gateway?: { id: string; label: string; base_url: string; profile: 'default' }
}
export interface BotVmCapabilities {
  available: boolean
  resources: Record<'cpu' | 'memory_mib' | 'disk_gib', { min: number; max: number; default: number }>
  credential_keys: string[]
}

/** Capture the owner once: reconnecting or switching gateways cannot move a request. */
export function botProvisioningClient() {
  const connectionId = activeGatewayConnectionId() || 'local'
  const owner = { connectionId, profile: 'default' }
  const prefix = '/api/plugins/bot-provisioning/v1'

  return {
    connectionId,
    capabilities: () => hermesApiAs<BotVmCapabilities>(owner, { path: `${prefix}/capabilities` }),
    list: () => hermesApiAs<{ requests: BotVmStatus[] }>(owner, { path: `${prefix}/requests` }),
    create: (body: BotVmRequest) =>
      hermesApiAs<BotVmStatus>(owner, { path: `${prefix}/requests`, method: 'POST', body }),
    register: (requestId: string) => window.hermesDesktop.connections.registerProvisioned({ connectionId, requestId })
  }
}
