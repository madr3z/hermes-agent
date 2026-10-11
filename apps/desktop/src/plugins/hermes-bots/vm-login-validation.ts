import type { BotVmCapabilities } from '@hermes/plugin-sdk'

export function validVmLogin(
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
    return false
  }

  const bytes = new TextEncoder().encode(password).length

  return (
    /^[a-z][a-z0-9_-]{0,31}$/.test(name) &&
    !policy.reserved_usernames.includes(name) &&
    password === confirmation &&
    !/[\0\r\n]/.test(password) &&
    bytes >= policy.password.min_bytes &&
    bytes <= policy.password.max_bytes
  )
}
