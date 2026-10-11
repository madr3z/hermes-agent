import type { BotVmCapabilities } from '@hermes/plugin-sdk'

export function vmLoginIssue(
  name: string,
  password: string,
  confirmation: string,
  policy: BotVmCapabilities['linux_account']
) {
  if (
    !policy ||
    policy.username !== 'bot_name' ||
    policy.username_pattern !== '^[a-z][a-z0-9_-]{0,31}$' ||
    !policy.password.required
  ) {
    return 'loginUnavailable'
  }

  if (!name) {
    return 'nameRequired'
  }

  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(name)) {
    return 'invalidUsername'
  }

  if (policy.reserved_usernames.includes(name)) {
    return 'reservedUsername'
  }

  if (!password) {
    return 'passwordRequired'
  }

  if (/[\0\r\n]/.test(password)) {
    return 'passwordInvalid'
  }

  const bytes = new TextEncoder().encode(password).length

  if (bytes < policy.password.min_bytes || bytes > policy.password.max_bytes) {
    return 'passwordLength'
  }

  if (!confirmation) {
    return 'confirmationRequired'
  }

  if (password !== confirmation) {
    return 'passwordMismatch'
  }

  return null
}

export function validVmLogin(
  name: string,
  password: string,
  confirmation: string,
  policy: BotVmCapabilities['linux_account']
) {
  return vmLoginIssue(name, password, confirmation, policy) === null
}
