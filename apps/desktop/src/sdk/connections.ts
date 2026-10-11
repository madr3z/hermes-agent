import { $profiles } from '@/store/profile'

import type { PluginProfileRoute } from './index'

export async function listConnections() {
  const bridge = window.hermesDesktop?.connections

  if (!bridge) {
    throw new Error('This Desktop build has no connection registry. Update Hermes Desktop.')
  }

  const registryPayload = await bridge.list()
  const rows = Array.isArray(registryPayload?.connections) ? registryPayload.connections : []

  return rows.map(connection => ({ ...connection, primary: connection.id === registryPayload.primary }))
}

/** Re-read Electron's current registry before retrying an exact-owner wake.
 *  A route that was removed or replaced while the first hydration wait ran is
 *  no longer authority to touch that backend, even when its labels still look
 *  identical. */
export async function pluginRouteStillRegistered(route: PluginProfileRoute): Promise<boolean> {
  const getProfileRoutes = window.hermesDesktop?.getProfileRoutes

  if (!getProfileRoutes) {
    return false
  }

  try {
    const routes = await getProfileRoutes($profiles.get().map(profile => profile.name))

    return routes.some(
      candidate =>
        candidate.connectionId === route.connectionId &&
        candidate.profile === route.profile &&
        candidate.targetProfile === route.targetProfile
    )
  } catch {
    return false
  }
}
