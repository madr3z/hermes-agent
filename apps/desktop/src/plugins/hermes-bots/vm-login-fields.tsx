import { Input } from '@hermes/plugin-sdk'

import { useBots } from './i18n'

interface VmLoginFieldsProps {
  name: string
  password: string
  confirmation: string
  disabled: boolean
  onPasswordChange: (value: string) => void
  onConfirmationChange: (value: string) => void
}

export function VmLoginFields({
  name,
  password,
  confirmation,
  disabled,
  onPasswordChange,
  onConfirmationChange
}: VmLoginFieldsProps) {
  const b = useBots().vm
  const mismatch = confirmation.length > 0 && password !== confirmation

  return (
    <>
      <label className="grid gap-1 text-xs">
        {b.username}
        <Input autoComplete="username" readOnly spellCheck={false} value={name} />
      </label>
      <p className="text-xs text-(--ui-text-secondary)">{b.loginDescription}</p>
      <label className="grid gap-1 text-xs">
        {b.password}
        <Input
          autoComplete="new-password"
          disabled={disabled}
          onChange={event => onPasswordChange(event.target.value)}
          type="password"
          value={password}
        />
      </label>
      <label className="grid gap-1 text-xs">
        {b.confirmPassword}
        <Input
          aria-invalid={mismatch}
          autoComplete="new-password"
          disabled={disabled}
          onChange={event => onConfirmationChange(event.target.value)}
          type="password"
          value={confirmation}
        />
      </label>
    </>
  )
}
