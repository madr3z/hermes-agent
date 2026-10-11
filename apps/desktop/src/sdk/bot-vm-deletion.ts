import type { BotVmCapabilities, BotVmStatus } from './bot-provisioning'

export interface VmDeleteSubmission {
  operation_id: string
  confirm_name: string
}
export interface VmDeleteOperation {
  operation_id: string
  request_id: string
  action: 'delete'
  phase: 'queued' | 'deleting' | 'deleted' | 'failed'
  error?: { code: string; message: string }
}

export function vmDeletionClient(
  requestId: string,
  request: <T>(path: string, body?: unknown) => Promise<T>,
  ownerScope: () => Promise<string>,
  forget: () => Promise<unknown>
) {
  const prefix = `/api/plugins/bot-provisioning/v1/requests/${encodeURIComponent(requestId)}`
  const operation = (id: string) => request<VmDeleteOperation>(`${prefix}/delete/${encodeURIComponent(id)}`)

  return {
    requestId,
    scope: async () => JSON.stringify({ owner: await ownerScope(), requestId }),
    capabilities: () => request<BotVmCapabilities>('/api/plugins/bot-provisioning/v1/capabilities'),
    status: () => request<BotVmStatus>(prefix),
    submit: (body: VmDeleteSubmission) => request<VmDeleteOperation>(`${prefix}/delete`, body),
    operation,
    forget: async (operationId: string) => {
      const receipt = await operation(operationId)

      if (receipt.phase !== 'deleted' || receipt.request_id !== requestId || receipt.operation_id !== operationId) {
        throw new Error('VM deletion is not complete. The bot remains registered.')
      }

      await forget()
    }
  }
}
