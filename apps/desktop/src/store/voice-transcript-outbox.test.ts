import { beforeEach, expect, it, vi } from 'vitest'

import { LiveTranscriptWriter } from '@/lib/voice-live-transcript'

import { moveVoiceTranscriptOutboxes, transcriptJournal } from './voice-transcript-outbox'

beforeEach(() => localStorage.clear())
it('recovers an unacknowledged final fragment after reload, scoped to its connection/profile/chat', async () => {
  const owner = { connectionId: 'remote', profile: 'bot' }
  const journal = transcriptJournal(owner, 'chat')
  const offline = new LiveTranscriptWriter('call', vi.fn().mockRejectedValue(new Error('offline')), vi.fn(), journal)
  offline.append({ eventId: 'tail', speaker: 'assistant', text: 'Only what was spoken', startMs: 0, endMs: 12 })
  expect(await offline.flush()).toBe(false)
  expect(transcriptJournal({ ...owner, connectionId: 'other' }, 'chat').read()).toEqual([])
  const send = vi.fn().mockResolvedValue({})
  const reloaded = new LiveTranscriptWriter('next-call', send, vi.fn(), transcriptJournal(owner, 'chat'))
  expect(await reloaded.flush()).toBe(true)
  expect(send).toHaveBeenCalledWith(expect.objectContaining({ call_id: 'call', event_id: 'tail' }))
  expect(journal.read()).toEqual([])
})
it('migrates and removes only the exact profile owner', () => {
  const value = {
    call_id: 'call',
    event_id: 'event',
    utterance_id: '1',
    speaker: 'user' as const,
    text: 'hi',
    start_ms: 0,
    end_ms: 1
  }

  transcriptJournal({ connectionId: 'local', profile: 'old' }, 'chat').put(value)
  transcriptJournal({ connectionId: 'remote', profile: 'old' }, 'chat').put(value)
  moveVoiceTranscriptOutboxes('local', 'old', 'new')
  expect(transcriptJournal({ connectionId: 'local', profile: 'new' }, 'chat').read()).toEqual([value])
  moveVoiceTranscriptOutboxes('local', 'new')
  expect(transcriptJournal({ connectionId: 'remote', profile: 'old' }, 'chat').read()).toEqual([value])
})
