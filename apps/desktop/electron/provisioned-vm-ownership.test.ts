import { expect, it } from 'vitest'

import { normalizeConnectionInput, normalizeRegistry } from './connection-registry'

it('preserves native VM provenance through cold reload and label edits, dropping it on endpoint edits', () => {
  const vm = { connectionId: 'main', requestId: '25d2e87a-80d9-41e2-a154-5fbbfae2bf70' }

  const registry = normalizeRegistry({
    connections: [
      { id: 'main', kind: 'remote', label: 'Main', url: 'https://main.example' },
      { id: 'guest', kind: 'remote', label: 'Guest', url: 'https://main.example/guest', provisionedVm: vm }
    ]
  })

  const guest = registry.connections.find(row => row.id === 'guest')!
  expect(guest.provisionedVm).toEqual(vm)
  expect(
    normalizeConnectionInput({ id: 'guest', kind: 'remote', label: 'Renamed', url: guest.url }, registry).provisionedVm
  ).toEqual(vm)
  expect(
    normalizeConnectionInput({ id: 'guest', kind: 'remote', label: 'Renamed', url: 'https://other.example' }, registry)
      .provisionedVm
  ).toBeUndefined()
})
