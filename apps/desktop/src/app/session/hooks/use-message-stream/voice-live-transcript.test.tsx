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

it.each([true, false])('keeps speech outside completion boundaries (stream exists: %s)', async hasStream => {
  const h = renderMessageStream('bot')
  h.states.set('bot', {
    ...h.state(),
    busy: true,
    sawAssistantPayload: true,
    streamId: hasStream ? 'answer' : null,
    messages: [
      { id: 'prompt', role: 'user', hidden: true, parts: [{ type: 'text', text: 'Do the task' }] },
      ...(hasStream
        ? [
            {
              id: 'answer',
              role: 'assistant' as const,
              pending: true,
              parts: [{ type: 'text' as const, text: 'Working' }]
            }
          ]
        : [])
    ]
  })
  await act(async () => {
    for (const role of ['user', 'assistant'] as const) {
      h.handleEvent({
        type: 'voice.live.transcript',
        session_id: 'bot',
        payload: {
          message: {
            role,
            text: `Continuing ${role} speech`,
            timestamp: 2,
            display_kind: 'voice_live',
            display_metadata: { voice_message_id: `voice:call:${role}`, call_id: 'call' }
          }
        }
      })
    }

    h.handleEvent({ type: 'message.complete', session_id: 'bot', payload: { text: 'Task complete' } })
  })
  const answers = h.state().messages.filter(message => message.role === 'assistant' && !message.voiceTranscript)
  expect(answers).toHaveLength(1)
  expect(answers[0].pending).not.toBe(true)
  expect(answers[0].parts).toEqual(expect.arrayContaining([expect.objectContaining({ text: 'Task complete' })]))
  expect(
    h
      .state()
      .messages.filter(message => message.voiceTranscript)
      .map(message => message.parts[0])
  ).toEqual([
    expect.objectContaining({ text: 'Continuing user speech' }),
    expect.objectContaining({ text: 'Continuing assistant speech' })
  ])
  expect(h.state().busy).toBe(false)
})
