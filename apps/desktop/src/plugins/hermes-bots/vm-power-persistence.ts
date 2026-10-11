import { type BotVmOwner, readKey, type VmPowerAction, writeKey } from '@hermes/plugin-sdk'

export interface PendingVmPower {
  operation_id: string
  action: VmPowerAction
}

function key(owner: BotVmOwner): string {
  // Machine scope, not profile scope: renaming/switching a profile cannot lose a retry.
  return `hermes-desktop-vm-power-v1:${encodeURIComponent(JSON.stringify(owner))}`
}

export function readPendingPower(owner: BotVmOwner): PendingVmPower | null {
  const raw = readKey(key(owner))

  if (!raw) {
    return null
  }

  try {
    const value = JSON.parse(raw) as PendingVmPower

    return /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(value.operation_id) &&
      ['start', 'stop', 'restart'].includes(value.action)
      ? value
      : null
  } catch {
    return null
  }
}

export function persistPendingPower(owner: BotVmOwner, operation: PendingVmPower | null): void {
  const serialized = operation === null ? null : JSON.stringify(operation)
  writeKey(key(owner), serialized)

  // Best-effort preferences are insufficient for a non-repeatable command.
  if (readKey(key(owner)) !== serialized) {
    throw new Error('Cannot persist the VM operation. No command was sent.')
  }
}
