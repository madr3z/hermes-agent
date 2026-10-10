import { Button, host } from '@hermes/plugin-sdk'

import { useBots } from './i18n'

export function VmCreateButton({
  busy,
  profileCreated,
  onClick
}: {
  busy: boolean
  profileCreated: string | null
  onClick?: () => void
}) {
  const b = useBots()

  if (!onClick) {
    return null
  }

  return (
    <Button
      disabled={busy || Boolean(profileCreated) || typeof host.botProvisioning !== 'function'}
      onClick={onClick}
      variant="secondary"
    >
      {b.vm.title}
    </Button>
  )
}
