import { act, cleanup, renderHook } from '@testing-library/react'
import type * as Nanostores from 'nanostores'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { $voiceLiveStatus } from '@/store/voice-live'

import { useComposerVoice } from './use-composer-voice'

const mocks = vi.hoisted(() => ({
  clearDraft: vi.fn(),
  liveEnabled: [] as boolean[],
  owner: {} as { connectionId?: string; profile?: string },
  conversationSubmits: [] as Array<(text: string) => Promise<void>>,
  onSubmit: vi.fn(async () => true),
  resetBrowseState: vi.fn(),
  triggerHaptic: vi.fn()
}))

vi.mock('@nanostores/react', () => ({
  useStore: (store: unknown) => store
}))

vi.mock('nanostores', async () => {
  const actual = await vi.importActual<typeof Nanostores>('nanostores')

  return { ...actual, computed: (deps: unknown, fn: unknown) => fn }
})

vi.mock('@/i18n', () => ({
  useI18n: () => ({
    t: {
      assistant: { thread: { readAloudFailed: '' } },
      notifications: { voice: { sayStopToEnd: () => '' } },
      settings: { config: { autosaveFailed: '' } }
    }
  })
}))

vi.mock('@/lib/haptics', () => ({
  triggerHaptic: mocks.triggerHaptic
}))

vi.mock('@/lib/spoken-reply', () => ({
  adoptSpokenReplySession: vi.fn(),
  markAssistantIdSpoken: vi.fn(),
  resolveSpokenReply: vi.fn(() => null)
}))

vi.mock('@/lib/tts-lease', () => ({
  CONVERSATION_LEASE: 'conversation',
  READ_ALOUD_LEASE: 'read-aloud',
  syncTtsLease: vi.fn(async () => undefined)
}))

vi.mock('@/lib/wake-indicator', () => ({
  clearWakeIndicator: vi.fn(),
  syncWakeIndicatorWithVoice: vi.fn(() => false)
}))

vi.mock('@/store/composer', () => ({
  $voiceConversationStartRequest: { get: () => null },
  takeVoiceConversationStart: vi.fn(() => false)
}))

vi.mock('@/store/composer-input-history', () => ({
  resetBrowseState: mocks.resetBrowseState
}))

vi.mock('@/store/gateway', () => ({
  $gateway: { get: () => null }
}))

vi.mock('@/store/notifications', () => ({
  notify: vi.fn(),
  notifyError: vi.fn()
}))

vi.mock('@/store/voice-prefs', () => ({
  $autoSpeakReplies: { get: () => false },
  $voiceStopPhrase: { get: () => null },
  setAutoSpeakReplies: vi.fn(async () => undefined)
}))

vi.mock('@/store/voice-transcript-writer', () => ({
  createVoiceTranscriptWriter: vi.fn(),
  recoverVoiceTranscripts: vi.fn()
}))

vi.mock('@/store/wake-word', () => ({
  resumeWakeAfterVoice: vi.fn(async () => undefined)
}))

vi.mock('../focus', () => ({
  onComposerDictationRequest: vi.fn(() => () => undefined),
  onComposerVoiceToggleRequest: vi.fn(() => () => undefined)
}))

vi.mock('../scope', () => ({
  useComposerScope: () => ({ $messages: { get: () => [] }, ...mocks.owner }),
  useComposerSurfaceId: () => null
}))

vi.mock('./use-auto-speak-replies', () => ({
  useAutoSpeakReplies: vi.fn()
}))

vi.mock('./use-voice-conversation', () => ({
  useVoiceConversation: ({ onSubmit }: { onSubmit: (text: string) => Promise<void> }) => {
    mocks.conversationSubmits.push(onSubmit)

    return {
      end: vi.fn(async () => undefined),
      level: 0,
      muted: false,
      start: vi.fn(async () => undefined),
      status: 'idle',
      stopTurn: vi.fn(),
      toggleMute: vi.fn()
    }
  }
}))

vi.mock('./use-voice-live-conversation', () => ({
  useVoiceLiveConversation: ({ enabled }: { enabled: boolean }) => {
    mocks.liveEnabled.push(enabled)

    return { end: vi.fn(), status: 'idle' }
  }
}))

vi.mock('./use-voice-recorder', () => ({
  useVoiceRecorder: () => ({
    dictate: vi.fn(),
    voiceActivityState: { elapsedSeconds: 0, level: 0, status: 'idle' },
    voiceStatus: 'idle'
  })
}))

describe('useComposerVoice voice submission', () => {
  afterEach(() => {
    cleanup()
    vi.clearAllMocks()
    mocks.conversationSubmits.length = 0
    mocks.liveEnabled.length = 0
    mocks.owner = {}
    $voiceLiveStatus.set(null)
    Reflect.deleteProperty(window, 'hermesDesktop')
  })

  it.each([true, false])(
    'uses the owned bot status without borrowing the controller engine (available: %s)',
    async success => {
      mocks.owner = { connectionId: 'assistant-vm', profile: 'default' }
      const status = { available: true, mode: 'chained' as const, model: 'gpt-live-1', reason: null, voice: 'marin' }
      $voiceLiveStatus.set(status)

      const api = vi.fn(async (request: { connectionId?: string }) => {
        if (request.connectionId === 'assistant-vm' && !success) {
          throw new Error('Owner unavailable')
        }

        return { ok: true, ...status, mode: request.connectionId === 'assistant-vm' ? 'gpt-live' : 'chained' }
      })

      Object.defineProperty(window, 'hermesDesktop', { configurable: true, value: { api } })

      const hook = renderHook(() =>
        useComposerVoice({
          busy: false,
          clearDraft: vi.fn(),
          disabled: false,
          focusInput: vi.fn(),
          insertText: vi.fn(),
          maxRecordingSeconds: 60,
          onSubmit: mocks.onSubmit,
          onTranscribeAudio: vi.fn(async () => ''),
          sessionId: 'assistant-chat',
          target: 'tile:assistant'
        })
      )

      await act(async () => {
        await hook.result.current.startConversation()
      })

      expect(api).toHaveBeenCalledWith(
        expect.objectContaining({
          connectionId: 'assistant-vm',
          profile: 'default',
          path: '/api/audio/voice-live/status'
        })
      )
      expect(mocks.liveEnabled.at(-1)).toBe(success)
      expect(hook.result.current.voiceConversationActive).toBe(success)
      expect($voiceLiveStatus.get()?.mode).toBe('chained')
    }
  )

  it('does not start a different owner when the scoped status arrives late', async () => {
    mocks.owner = { connectionId: 'assistant-vm', profile: 'default' }
    let answer!: (status: unknown) => void

    const api = vi.fn((request: { connectionId?: string }) =>
      request.connectionId === 'assistant-vm'
        ? new Promise(resolve => {
            answer = resolve
          })
        : Promise.resolve({ ok: true, mode: 'chained' })
    )

    Object.defineProperty(window, 'hermesDesktop', { configurable: true, value: { api } })

    const hook = renderHook(() =>
      useComposerVoice({
        busy: false,
        clearDraft: vi.fn(),
        disabled: false,
        focusInput: vi.fn(),
        insertText: vi.fn(),
        maxRecordingSeconds: 60,
        onSubmit: mocks.onSubmit,
        onTranscribeAudio: vi.fn(async () => ''),
        sessionId: 'assistant-chat',
        target: 'tile:assistant'
      })
    )

    let activation!: Promise<void>
    await act(async () => {
      activation = hook.result.current.startConversation()
    })
    mocks.owner = { connectionId: 'other-vm', profile: 'default' }
    hook.rerender()
    await act(async () => {
      answer({ ok: true, available: true, mode: 'gpt-live', model: 'gpt-live-1', voice: 'marin', reason: null })
      await activation
    })

    expect(hook.result.current.voiceConversationActive).toBe(false)
    expect(mocks.liveEnabled.at(-1)).toBe(false)
  })

  it('uses live busy state when a retained voice callback submits after barge-in', async () => {
    const hook = renderHook(
      ({ busy }) =>
        useComposerVoice({
          busy,
          clearDraft: mocks.clearDraft,
          disabled: false,
          focusInput: vi.fn(),
          insertText: vi.fn(),
          maxRecordingSeconds: 60,
          onSubmit: mocks.onSubmit,
          onTranscribeAudio: vi.fn(async () => ''),
          sessionId: 'session-1',
          target: 'tile:test'
        }),
      { initialProps: { busy: true } }
    )

    const retainedSubmit = mocks.conversationSubmits[0]

    hook.rerender({ busy: false })
    await act(async () => retainedSubmit('change direction'))

    expect(mocks.onSubmit).toHaveBeenCalledWith('change direction', { voiceTurn: true })
    expect(mocks.clearDraft).toHaveBeenCalledTimes(1)
    expect(mocks.resetBrowseState).toHaveBeenCalledWith('session-1')
    expect(mocks.triggerHaptic).toHaveBeenCalledWith('submit')

    hook.rerender({ busy: true })
    await act(async () => retainedSubmit('do not double-submit'))

    expect(mocks.onSubmit).toHaveBeenCalledTimes(1)
    expect(mocks.clearDraft).toHaveBeenCalledTimes(1)
  })
})
