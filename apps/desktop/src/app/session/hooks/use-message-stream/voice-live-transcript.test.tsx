import { act, cleanup } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'

import { renderMessageStream } from './test-harness'

afterEach(cleanup)

it('committed spoken events update the owning chat without opening a model turn', async () => {
  const h = renderMessageStream('bot')

  const message = {
    role: 'user' as const,
    content: null,
    text: 'Hello',
    timestamp: 1,
    display_kind: 'voice_live',
    display_metadata: { voice_message_id: 'voice:call:one', call_id: 'call' }
  }

  await act(async () => {
    h.handleEvent({ type: 'voice.live.transcript', session_id: 'bot', payload: { message } })
    h.handleEvent({ type: 'voice.live.transcript', session_id: 'bot', payload: { message } })
    h.handleEvent({
      type: 'voice.live.transcript',
      session_id: 'bot',
      payload: { message: { ...message, text: 'Hello there' } }
    })
  })
  expect(h.state().messages).toHaveLength(1)
  expect(h.text()).toBe('Hello there')
  expect(h.state().busy).toBe(false)
  expect(h.state().awaitingResponse).toBe(false)
})
