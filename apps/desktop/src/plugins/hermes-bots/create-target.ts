import { host } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'

import type { ConnectionRow } from './types'

/** Preserve the selected gateway across every phase of lazy profile creation. */
export function createTargetRequest(remote: boolean, connectionId: string) {
  return <T>(method: string, params: Record<string, unknown> = {}): Promise<T> =>
    remote
      ? host.requestProfile(
          { connectionId, mode: 'remote', profile: 'default', targetProfile: 'default' },
          method,
          params
        )
      : host.request(method, params)
}

export function useCreationConnections(open: boolean) {
  const [connections, setConnections] = useState<ConnectionRow[] | null>(null)
  useEffect(() => {
    if (
      !open ||
      connections !== null ||
      typeof host.connections !== 'function' ||
      typeof host.requestProfile !== 'function'
    ) {
      return
    }

    host
      .connections()
      // host.connections() returns the registry ROWS on current SDKs, but the
      // envelope object ({version, primary, connections: [...]}) on desktops
      // that predate the SDK-side unwrap — accept both shapes.
      .then((value: ConnectionRow[] | { connections?: ConnectionRow[] }) =>
        setConnections(Array.isArray(value) ? value : Array.isArray(value?.connections) ? value.connections : [])
      )
      .catch(() => setConnections([]))
  }, [open, connections])

  return connections
}

export function creationTargetLabel(remote: boolean, connections: ConnectionRow[] | null, target: string) {
  return remote ? (connections || []).find(connection => connection.id === target)?.label || target : ''
}
