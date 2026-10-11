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
