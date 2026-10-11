import type { RegistryConnection } from './connection-registry'

export function normalizeProvisionedVm(kind: string, value: unknown): Pick<RegistryConnection, 'provisionedVm'> {
  const vm = value as RegistryConnection['provisionedVm']

  if (
    kind !== 'remote' ||
    typeof vm?.connectionId !== 'string' ||
    !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(vm?.requestId)
  ) {
    return {}
  }

  return { provisionedVm: { connectionId: vm.connectionId, requestId: vm.requestId } }
}

/** Label edits keep provenance; endpoint/auth changes cease to describe that VM. */
export function retainedProvisionedVm(
  kind: string,
  url: string,
  authMode: string,
  previous?: RegistryConnection
): Pick<RegistryConnection, 'provisionedVm'> {
  const vm =
    kind === 'remote' && previous?.url === url && previous.authMode === authMode ? previous.provisionedVm : undefined

  return vm ? { provisionedVm: vm } : {}
}

/** Only native provenance and the canonical HTTPS proxy path can borrow a main's authority. */
export function provisionedVmMain(connections: RegistryConnection[], guestId: string): RegistryConnection | null {
  const guest = connections.find(entry => entry?.id === guestId)
  const vm = guest?.provisionedVm
  const main = connections.find(entry => entry?.id === vm?.connectionId)

  if (
    !vm ||
    !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(vm.requestId) ||
    guest?.kind !== 'remote' ||
    main?.kind !== 'remote' ||
    main.provisionedVm ||
    guest.authMode !== main.authMode
  )
    {return null}

  try {
    const base = new URL(main.url || '')

    if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) {return null}
    const expected = (main.url || '').replace(/\/$/, '') + `/api/plugins/bot-provisioning/v1/gateways/${vm.requestId}`

    return guest.url === expected ? main : null
  } catch {
    return null
  }
}
