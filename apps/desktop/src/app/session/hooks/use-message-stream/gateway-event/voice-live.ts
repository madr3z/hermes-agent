import { upsertVoiceMessage, voiceChatMessage } from '@/lib/voice-live-transcript'
import type { SessionMessage } from '@/types/hermes'

import type { GatewayEventContext } from './types'

export function handleVoiceLiveEvent({ event, sessionId, deps }: GatewayEventContext): boolean {
  if (event.type !== 'voice.live.transcript') {
    return false
  }

  if (!sessionId) {
    return true
  }
  const payload = event.payload as { message?: SessionMessage } | undefined
  const message = payload?.message && voiceChatMessage(payload.message)

  if (message) {
    deps.updateSessionState(sessionId, state => ({ ...state, messages: upsertVoiceMessage(state.messages, message) }))
  }

  return true
}
