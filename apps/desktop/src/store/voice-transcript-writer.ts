import { withSessionNotFoundResume } from '@/app/session/hooks/use-prompt-actions/utils'
import { LiveTranscriptWriter } from '@/lib/voice-live-transcript'

import { $gateway } from './gateway'
import { requestForSessionProfile } from './session-request-router'
import { knownOwnerForSession, storedSessionIdForRuntimeId } from './session-states'
import { transcriptJournal } from './voice-transcript-outbox'

export function createVoiceTranscriptWriter(
  sessionId: string,
  onError: (error: unknown) => void
): LiveTranscriptWriter {
  const owner = knownOwnerForSession(sessionId)
  const stored = storedSessionIdForRuntimeId(sessionId)
  const gateway = $gateway.get()

  if (!gateway || !owner || typeof owner === 'string' || !stored) {
    throw new Error('Voice chat owner is unavailable')
  }

  const request = <T>(method: string, params?: Record<string, unknown>) =>
    requestForSessionProfile<T>(owner, (m, p) => gateway.request(m, p), method, params)

  let runtime = sessionId

  return new LiveTranscriptWriter(
    crypto.randomUUID(),
    async fragment => {
      const result = await withSessionNotFoundResume(
        runtime,
        stored,
        id => request('voice.live.transcript.append', { session_id: id, ...fragment }),
        { requestGateway: request, resolveProfile: async () => owner.targetProfile ?? owner.profile }
      )

      runtime = result.sessionId

      return result.result
    },
    onError,
    transcriptJournal(owner, stored)
  )
}

export function recoverVoiceTranscripts(sessionId: string, onError: (error: unknown) => void): void {
  const owner = knownOwnerForSession(sessionId)

  if (!owner || typeof owner === 'string' || !storedSessionIdForRuntimeId(sessionId) || !$gateway.get()) {
    return
  }

  try {
    void createVoiceTranscriptWriter(sessionId, onError).flush()
  } catch (error) {
    onError(error)
  }
}
