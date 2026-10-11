import { host } from '@hermes/plugin-sdk'
import type { PluginProfileRoute } from '@hermes/plugin-sdk'

import { botScreenRoute, displayRequest } from './screen-connection'
import type { RosterRow } from './types'

export interface ScreenTaskContinuation {
  sessionId: string
  storedId: string
  route: string | PluginProfileRoute
  turnId: string
  submissionStarted: boolean
}

/** Capture only the chat owned by this computer. Never select a different recent chat. */
export function captureScreenTask(bot: RosterRow): ScreenTaskContinuation | null {
  const owner = host.state?.focusedSessionOwner?.get()
  const sessionId = host.state?.focusedSessionId?.get()
  const storedId = host.state?.focusedStoredSessionId?.get()
  const route = botScreenRoute(bot)
  if (!owner || !sessionId || !storedId || !route) return null
  const profile = typeof route === 'string' ? route : route.targetProfile || route.profile
  const connection = typeof route === 'string' ? 'local' : route.connectionId || 'local'
  if (owner.profile !== profile || owner.connectionId !== connection) return null
  return {
    sessionId,
    storedId,
    route: typeof route === 'string' ? route : { ...route },
    turnId: 'desktop-handoff-' + crypto.randomUUID(),
    submissionStarted: false
  }
}

export async function continueScreenTask(bot: RosterRow, task: ScreenTaskContinuation): Promise<void> {
  const returnToChat = () =>
    host.openSession(task.storedId, typeof task.route === 'string' ? { profile: task.route } : { route: task.route })
  if (task.submissionStarted) {
    await returnToChat()
    return
  }
  // A takeover on another device must still prevent continuation after an uncertain reply.
  const status = await displayRequest<{ lease: { holder: string } }>(bot, 'display.status')
  if (status.lease.holder !== 'agent')
    throw new Error('A person still controls this computer. The task has not resumed.')
  task.submissionStarted = true
  await host.requestProfile(task.route, 'prompt.submit', {
    session_id: task.sessionId,
    queued: true,
    client_turn_id: task.turnId,
    text: 'I have handed this bot’s computer back. Check the current page and signed-in account before continuing the task that needed manual sign-in. If sign-in is incomplete, ask me to finish it.'
  })
  await returnToChat()
}
