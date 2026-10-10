import { chatMessageText, textPart } from '@/lib/chat-messages/parts'
import type { ChatMessage } from '@/lib/chat-messages/types'
import type { SessionMessage } from '@/types/hermes'

import { sanitizeTextForSpeech } from './speech-text'
import type { LiveTranscriptFragment } from './voice-live'

/** Both RPC acknowledgements and replay events carry the full committed utterance. */
export function voiceChatMessage(message: SessionMessage): ChatMessage | null {
  const metadata = message.display_metadata
  const id = metadata && typeof metadata === 'object' ? (metadata as Record<string, unknown>).voice_message_id : null

  if (typeof id !== 'string' || (message.role !== 'user' && message.role !== 'assistant')) {
    return null
  }

  return {
    id,
    role: message.role,
    parts: [textPart(typeof message.text === 'string' ? message.text : '', message.timestamp)],
    timestamp: message.timestamp,
    pending: false,
    voiceTranscript: true,
    serverRowSpan: 0
  }
}

export function upsertVoiceMessage(messages: ChatMessage[], message: ChatMessage): ChatMessage[] {
  const index = messages.findIndex(m => m.id === message.id)

  if (index < 0) {
    return suppressVoiceEchoes([...messages, message])
  }

  // Late snapshots cannot shorten an already committed utterance.
  const oldText = messages[index].parts
    .filter(p => p.type === 'text')
    .map(p => p.text)
    .join('')

  const text = message.parts
    .filter(p => p.type === 'text')
    .map(p => p.text)
    .join('')

  if (oldText.length >= text.length) {
    return messages
  }

  return suppressVoiceEchoes(messages.map((m, i) => (i === index ? message : m)))
}

/** Exact read-aloud echoes share the existing answer bubble; paraphrases remain visible. */
export function suppressVoiceEchoes(messages: ChatMessage[]): ChatMessage[] {
  const normalized = (message: ChatMessage) =>
    sanitizeTextForSpeech(chatMessageText(message)).replace(/\s+/g, ' ').trim()

  const answers = new Map<number, Set<string>>()
  let segment = 0

  for (const message of messages) {
    if (message.role === 'user' && !message.hidden) {
      segment += 1
    }

    if (message.role === 'assistant' && !message.voiceTranscript && !message.hidden) {
      const texts = answers.get(segment) ?? new Set<string>()
      texts.add(normalized(message))
      answers.set(segment, texts)
    }
  }

  segment = 0

  return messages.map(message => {
    if (message.role === 'user' && !message.hidden) {
      segment += 1
    }

    if (!message.voiceTranscript || message.role !== 'assistant') {
      return message
    }
    const text = normalized(message)
    const hidden = Boolean(text && answers.get(segment)?.has(text))

    return Boolean(message.hidden) === hidden ? message : { ...message, hidden }
  })
}

export interface TranscriptWrite {
  call_id: string
  event_id: string
  utterance_id: string
  speaker: 'user' | 'assistant'
  text: string
  start_ms: number
  end_ms: number
}

export interface TranscriptJournal {
  read: () => TranscriptWrite[]
  put: (fragment: TranscriptWrite) => void
  remove: (fragment: TranscriptWrite) => void
}

/** Serial writes preserve speech order. The journal keeps unacknowledged fragments across reloads. */
export class LiveTranscriptWriter {
  private tail: Promise<void> = Promise.resolve()
  private previous: LiveTranscriptFragment | null = null
  private utterance = 0
  private sequence = 0
  private seen = new Set<string>()
  private pending: TranscriptWrite[]
  constructor(
    private readonly callId: string,
    private readonly write: (fragment: TranscriptWrite) => Promise<unknown>,
    private readonly onError: (error: unknown) => void,
    private readonly journal?: TranscriptJournal
  ) {
    this.pending = journal?.read() ?? []

    if (this.pending.length) {
      this.drain()
    }
  }

  append(fragment: LiveTranscriptFragment): void {
    if (!fragment.text) {
      return
    }
    const eventId = fragment.eventId ?? `fragment-${++this.sequence}`

    if (this.seen.has(eventId)) {
      return
    }
    this.seen.add(eventId)

    if (!this.previous || this.previous.speaker !== fragment.speaker || fragment.startMs - this.previous.endMs > 1500) {
      this.utterance += 1
    }

    this.previous = fragment

    const value: TranscriptWrite = {
      call_id: this.callId,
      event_id: eventId,
      utterance_id: String(this.utterance),
      speaker: fragment.speaker,
      text: fragment.text,
      start_ms: fragment.startMs,
      end_ms: fragment.endMs
    }

    try {
      this.journal?.put(value)
    } catch (error) {
      this.onError(error)
    }

    this.pending.push(value)
    this.drain()
  }

  private drain(): void {
    this.tail = this.tail.then(async () => {
      while (this.pending.length) {
        const value = this.pending[0]

        try {
          try {
            await this.write(value)
          } catch {
            await this.write(value)
          }

          this.journal?.remove(value)
          this.pending.shift()
        } catch (error) {
          this.onError(error)

          break
        }
      }
    })
  }

  async flush(): Promise<boolean> {
    this.drain()
    await this.tail

    return this.pending.length === 0
  }
}

/** Keep display-only speech outside the ordinary model-row hydration state machine. */
export function forEachTranscriptMessage(
  messages: SessionMessage[],
  ordinary: (message: SessionMessage, index: number) => void,
  spoken: (message: ChatMessage, index: number) => void
): void {
  messages.forEach((message, index) => {
    if (message.display_kind !== 'voice_live') {
      ordinary(message, index)

      return
    }

    const voice = voiceChatMessage(message)

    if (voice) {
      spoken(voice, index)
    }
  })
}
