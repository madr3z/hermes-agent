import { expect, it } from 'vitest'

import { mergeOlderTranscriptPage } from '@/app/chat/transcript-backfill'
import { toChatMessages } from '@/lib/chat-messages'
import type { SessionMessage } from '@/types/hermes'

import { tailStateFromPage } from './transcript-tail'

const speech: SessionMessage[] = Array.from({ length: 160 }, (_, i) => ({
  role: 'user',
  content: null,
  text: 'Spoken words',
  timestamp: i + 1,
  display_kind: 'voice_live',
  display_metadata: { voice_message_id: `voice:call:${i}`, call_id: 'call', start_ms: i, end_ms: i + 1 }
}))

it('uses the backend ordinary-row count for paging and deduplicates repeated speech overlays', () => {
  const ordinary: SessionMessage[] = Array.from({ length: 120 }, (_, i) => ({
    role: 'user',
    content: `Typed ${i}`,
    row_id: i + 1,
    timestamp: 200 + i
  }))

  const page = {
    messages: [...speech, ...ordinary],
    pagination: { offset: 0, limit: 120, returned: 120, order: 'latest' as const }
  }

  expect(tailStateFromPage(page)).toMatchObject({ nextOffset: 120, possiblyTruncated: true })
  const existing = toChatMessages(page.messages)
  expect(mergeOlderTranscriptPage(existing, toChatMessages(speech))).toBe(existing)
})

it('a speech-only transcript cannot arm endless ordinary-row backfill', () => {
  const state = tailStateFromPage({
    messages: speech,
    pagination: { offset: 0, limit: 120, returned: 0, order: 'latest' }
  })

  expect(state).toMatchObject({ nextOffset: 0, possiblyTruncated: false })
})
