import type { TranscriptJournal, TranscriptWrite } from '@/lib/voice-live-transcript'

const PREFIX = 'hermes:voice-transcript-outbox:'
interface Owner {
  connectionId: string
  profile: string
}

export function transcriptJournal(owner: Owner, storedSessionId: string): TranscriptJournal {
  const key = PREFIX + JSON.stringify([owner.connectionId, owner.profile, storedSessionId])
  const read = (): TranscriptWrite[] => JSON.parse(localStorage.getItem(key) ?? '[]') as TranscriptWrite[]

  const save = (values: TranscriptWrite[]) => {
    if (values.length) {
      localStorage.setItem(key, JSON.stringify(values))
    } else {
      localStorage.removeItem(key)
    }
  }

  const same = (a: TranscriptWrite, b: TranscriptWrite) => a.call_id === b.call_id && a.event_id === b.event_id

  return {
    read,
    put: value => {
      const values = read()

      if (!values.some(v => same(v, value))) {
        save([...values, value])
      }
    },
    remove: value => save(read().filter(v => !same(v, value)))
  }
}

/** Profile lifecycle uses the same connection/profile scope as the writer. */
export function moveVoiceTranscriptOutboxes(connectionId: string, profile: string, nextProfile?: string): void {
  const keys = Array.from({ length: localStorage.length }, (_, index) => localStorage.key(index))

  for (const key of keys) {
    if (!key) {
      continue
    }

    if (!key.startsWith(PREFIX)) {
      continue
    }
    const scope = JSON.parse(key.slice(PREFIX.length)) as string[]

    if (scope[0] !== connectionId || scope[1] !== profile) {
      continue
    }

    if (nextProfile) {
      const next = PREFIX + JSON.stringify([connectionId, nextProfile, scope[2]])
      const pending = JSON.parse(localStorage.getItem(next) ?? '[]') as TranscriptWrite[]
      const values = JSON.parse(localStorage.getItem(key) ?? '[]') as TranscriptWrite[]
      localStorage.setItem(next, JSON.stringify([...pending, ...values]))
    }

    localStorage.removeItem(key)
  }
}
