import type { BotVmCapabilities } from '@hermes/plugin-sdk'

import type { VmMessages } from './vm-i18n'
import { vmLoginIssue } from './vm-login-validation'

export function vmCreateProblem(
  capabilities: BotVmCapabilities | null,
  name: string,
  password: string,
  confirmation: string,
  resources: { cpu: number; memory_mib: number; disk_gib: number },
  b: VmMessages
): string | null {
  if (!capabilities) {
    return b.connecting
  }

  if (!capabilities.available) {
    return b.unavailable
  }

  const issue = vmLoginIssue(name, password, confirmation, capabilities.linux_account)

  if (issue) {
    const policy = capabilities.linux_account?.password

    return issue === 'passwordLength' && policy
      ? b.passwordLength.replace('{min}', String(policy.min_bytes)).replace('{max}', String(policy.max_bytes))
      : b[issue]
  }

  for (const key of ['cpu', 'memory_mib', 'disk_gib'] as const) {
    const value = resources[key]
    const bounds = capabilities.resources[key]

    if (!Number.isInteger(value) || value < bounds.min || value > bounds.max) {
      return b.resourceBounds
        .replace('{resource}', b[key])
        .replace('{min}', String(bounds.min))
        .replace('{max}', String(bounds.max))
    }
  }

  return null
}
