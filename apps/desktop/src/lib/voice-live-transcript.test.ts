import { describe, expect, it, vi } from 'vitest'

import { toChatMessages } from './chat-messages'
import { LiveTranscriptWriter, upsertVoiceMessage, voiceChatMessage } from './voice-live-transcript'

const row = (text: string) => ({
  role: 'assistant' as const,
  content: null,
  text,
  timestamp: 12,
  display_kind: 'voice_live',
  display_metadata: { voice_message_id: 'voice:call:one', call_id: 'call', start_ms: 1, end_ms: 2 }
})

describe('spoken transcripts', () => {
  it('hydrates and replays one stable bubble, without folding speech into delegated tool output', () => {
    const speech = voiceChatMessage(row('Hello'))!
    let messages = toChatMessages([row('Hello')])
    expect(messages).toEqual([speech])
    messages = upsertVoiceMessage(messages, speech)
    messages = upsertVoiceMessage(messages, voiceChatMessage(row('Hello there'))!)
    messages = upsertVoiceMessage(messages, speech)
    expect(messages).toHaveLength(1)
    expect(messages[0].parts[0]).toMatchObject({ text: 'Hello there' })
    expect(messages[0].voiceTranscript).toBe(true)
  })

  it('retries with identical IDs, orders speakers, deduplicates vendor events and flushes the final fragment', async () => {
    const write = vi.fn().mockRejectedValueOnce(new Error('lost ACK')).mockResolvedValue({})
    const writer = new LiveTranscriptWriter('call', write, vi.fn())
    const fragment = { eventId: 'one', speaker: 'user' as const, text: 'Hi', startMs: 0, endMs: 100 }
    writer.append(fragment)
    writer.append(fragment)
    writer.append({ eventId: 'two', speaker: 'assistant', text: 'Hello', startMs: 110, endMs: 200 })
    expect(await writer.flush()).toBe(true)
    expect(write).toHaveBeenCalledTimes(3)
    expect(write.mock.calls[0]).toEqual(write.mock.calls[1])
    expect(write.mock.calls[2][0]).toMatchObject({ utterance_id: '2', text: 'Hello' })
  })
})

it('collapses an exact delegated read-aloud echo while retaining a spoken paraphrase', () => {
  const normal = { role: 'assistant' as const, content: 'The result is ready.', timestamp: 1 }
  const exact = toChatMessages([normal, row('The result is ready.')])
  expect(exact.filter(message => !message.hidden)).toHaveLength(1)
  expect(toChatMessages([row('The result is ready.'), normal]).filter(message => !message.hidden)).toHaveLength(1)
  const paraphrase = toChatMessages([normal, row('I have it ready for you.')])
  expect(paraphrase.filter(message => !message.hidden)).toHaveLength(2)
})
