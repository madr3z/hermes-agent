import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import type { ComponentProps } from 'react'
import { afterEach, expect, it, vi } from 'vitest'

import type { RosterRow } from './types'
import { VmDeleteMenuItem } from './vm-delete-menu'
import { vmEn } from './vm-i18n'

const mocks = vi.hoisted(() => ({ connections: vi.fn(), botVmOwner: vi.fn(), capabilities: vi.fn() }))
vi.mock('@hermes/plugin-sdk', () => ({
  ContextMenuItem: ({
    onSelect,
    variant: _variant,
    ...props
  }: ComponentProps<'button'> & { onSelect: () => void; variant: string }) => <button {...props} onClick={onSelect} />,
  ContextMenuSeparator: () => <hr />,
  useI18n: () => ({ t: { common: { delete: 'Delete' } } }),
  host: {
    connections: mocks.connections,
    botVmOwner: mocks.botVmOwner,
    botVm: () => ({ capabilities: mocks.capabilities })
  }
}))
vi.mock('./i18n', () => ({ useBots: () => ({ vm: vmEn }) }))
vi.mock('./data', () => ({ isDefaultBot: (bot: RosterRow) => bot.name === 'default' }))
vi.mock('./screen-connection', () => ({ botScreenRoute: (bot: RosterRow) => bot.route ?? bot.name }))
afterEach(() => {
  cleanup()
  vi.resetAllMocks()
})

it.each(['default', 'research'])(
  'routes the existing managed bot delete action to VM confirmation with no profile-only fallback: %s',
  async name => {
    const owner = {
      connectionId: 'main',
      requestId: 'managed-request',
      guestConnectionId: 'guest',
      mainUrl: 'https://main.example',
      guestUrl: 'https://main.example/guest'
    }

    mocks.connections.mockResolvedValue([
      { id: 'guest', provisionedVm: { connectionId: 'main', requestId: owner.requestId } }
    ])
    mocks.botVmOwner.mockResolvedValue(owner)
    mocks.capabilities.mockResolvedValue({ vm_delete: true })
    const onDelete = vi.fn()

    const bot = {
      name,
      route: { connectionId: 'guest', mode: 'remote', profile: name, targetProfile: name }
    } as RosterRow

    render(<VmDeleteMenuItem bot={bot} onDelete={onDelete} />)
    fireEvent.click(await screen.findByText(vmEn.deleteAction))
    expect(onDelete).toHaveBeenCalledWith({ ...bot, vmOwner: owner })
    expect(screen.queryByText('Delete')).toBeNull()
    cleanup()
    mocks.capabilities.mockResolvedValue({ vm_delete: false })
    render(<VmDeleteMenuItem bot={bot} onDelete={onDelete} />)
    await waitFor(() => expect(mocks.capabilities).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('button')).toBeNull()
    mocks.botVmOwner.mockResolvedValue(null)
    cleanup()
    render(<VmDeleteMenuItem bot={bot} onDelete={onDelete} />)
    await waitFor(() => expect(mocks.botVmOwner).toHaveBeenCalledTimes(3))
    expect(screen.queryByRole('button')).toBeNull()
  }
)

it('keeps ordinary unmanaged profile deletion and never offers VM deletion for the external pilot default', async () => {
  const onDelete = vi.fn()
  const bot = { name: 'research' } as RosterRow
  render(<VmDeleteMenuItem bot={bot} onDelete={onDelete} />)
  fireEvent.click(screen.getByText('Delete'))
  expect(onDelete).toHaveBeenCalledWith(bot)
  cleanup()
  mocks.connections.mockResolvedValue([{ id: 'pilot', kind: 'ssh' }])
  render(
    <VmDeleteMenuItem
      bot={
        {
          name: 'default',
          route: { connectionId: 'pilot', mode: 'remote', profile: 'default', targetProfile: 'default' }
        } as RosterRow
      }
      onDelete={onDelete}
    />
  )
  await waitFor(() => expect(mocks.connections).toHaveBeenCalled())
  expect(screen.queryByRole('button')).toBeNull()
  expect(mocks.botVmOwner).not.toHaveBeenCalled()
})
