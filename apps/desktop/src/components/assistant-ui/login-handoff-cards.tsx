import { useEffect, useRef, useState } from 'react'

import type { HermesGateway } from '@/hermes'

export interface LoginHandoffRequest {
  id: string
  provider: string
  name: string
  owner_profile: string
  scopes: string[]
  status: string
  detail: string
  account_ref: string
  user_code: string
  verification_url: string
  auth_url: string
  expires_at: number
  continued: boolean
}

interface LoginHandoffCardsProps {
  gateway: HermesGateway | null
  sessionId: string | null
}

const secureAuthorizationURL = (raw: string): URL => {
  const url = new URL(raw)
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.hash) {
    throw new Error('The provider did not return a secure sign-in URL.')
  }
  return url
}

interface NativeListener {
  id: string
  redirectUri: string
}

async function launchAuthorization(
  pending: LoginHandoffRequest,
  native: NativeListener | undefined,
  relay: (params: Record<string, unknown>) => Promise<unknown>,
  active: () => boolean
): Promise<boolean> {
  if (pending.provider === 'openai-codex' && pending.user_code) {
    if (pending.verification_url !== 'https://auth.openai.com/codex/device')
      throw new Error('Unexpected OpenAI sign-in URL.')
    await window.hermesDesktop.openExternal(pending.verification_url)
    return true
  }
  if (!pending.auth_url || !native) return false
  const url = secureAuthorizationURL(pending.auth_url)
  if (url.searchParams.get('redirect_uri') !== native.redirectUri) {
    throw new Error('This provider requires its registered Mac callback. Use its supported connector settings flow.')
  }
  const callback = window.hermesDesktop.mcpOauth!.wait(native.id)
  await window.hermesDesktop.openExternal(url.href)
  const result = await callback
  if (!active()) return true
  if (!result.state) throw new Error('Sign-in browser closed or expired. Retry or cancel.')
  await relay({ ...result, iss: result.iss || undefined })
  return true
}

/** UI-only metadata: never copy the URL or device code into the transcript. */
export function LoginHandoffCards({ gateway, sessionId }: LoginHandoffCardsProps) {
  const [requests, setRequests] = useState<LoginHandoffRequest[]>([])
  const [error, setError] = useState('')
  const [working, setWorking] = useState(false)
  const generation = useRef(0)
  const attemptGeneration = useRef(0)
  const listener = useRef<string | null>(null)

  useEffect(() => {
    const current = ++generation.current
    setRequests([])
    setError('')
    setWorking(false)
    if (!gateway || !sessionId) return
    let timer: ReturnType<typeof setTimeout>
    const refresh = async () => {
      try {
        const result = await gateway.request<{ requests: LoginHandoffRequest[] }>('login.handoff.list', {
          session_id: sessionId
        })
        if (current === generation.current) setRequests(result.requests)
      } catch (failure) {
        if (
          current === generation.current &&
          !String(failure).includes('not found') &&
          !String(failure).includes('-32601')
        ) {
          setError('Sign-in status is unavailable. Reconnect to this bot to check it.')
        }
      }
      if (current === generation.current) timer = setTimeout(() => void refresh(), 2000)
    }
    void refresh()
    return () => {
      ++generation.current
      clearTimeout(timer)
      if (listener.current) void window.hermesDesktop.mcpOauth?.cancel(listener.current)
      listener.current = null
    }
  }, [gateway, sessionId])

  const action = async (verb: string, request: LoginHandoffRequest, extra = {}) => {
    if (!gateway || !sessionId) throw new Error('Reconnect to this bot first.')
    return gateway.request<{ request: LoginHandoffRequest }>(`login.handoff.${verb}`, {
      session_id: sessionId,
      request_id: request.id,
      ...extra
    })
  }

  const signIn = async (request: LoginHandoffRequest) => {
    const current = generation.current
    const attempt = ++attemptGeneration.current
    const active = () => current === generation.current && attempt === attemptGeneration.current
    setWorking(true)
    setError('')
    let native: { id: string; redirectUri: string } | undefined
    try {
      if (request.provider === 'mcp') {
        if (!window.hermesDesktop.mcpOauth) throw new Error('Update Hermes Desktop to support native callbacks.')
        native = await window.hermesDesktop.mcpOauth.listen()
        listener.current = native.id
      }
      await action('start', request, native ? { client_redirect_uri: native.redirectUri } : {})
      for (let poll = 0; poll < 30; poll++) {
        if (!active() || !gateway || !sessionId) return
        const result = await gateway.request<{ requests: LoginHandoffRequest[] }>('login.handoff.list', {
          session_id: sessionId
        })
        if (!active()) return
        setRequests(result.requests)
        const pending = result.requests.find(item => item.id === request.id)
        if (!pending || pending.status !== 'awaiting_human') return
        if (await launchAuthorization(pending, native, params => action('callback', pending, params), active)) return
        await new Promise(resolve => setTimeout(resolve, 1000))
      }
      throw new Error('The provider has not supplied sign-in yet. Retry after checking the bot connection.')
    } catch (failure) {
      if (active()) setError(failure instanceof Error ? failure.message : 'Sign-in could not start. Retry.')
    } finally {
      if (native) await window.hermesDesktop.mcpOauth?.cancel(native.id).catch(() => {})
      if (active()) {
        listener.current = null
        setWorking(false)
      }
    }
  }

  const respond = async (verb: string, request: LoginHandoffRequest) => {
    const current = generation.current
    try {
      if (verb === 'cancel') {
        ++attemptGeneration.current
        setWorking(false)
      }
      if (verb === 'cancel' && listener.current) await window.hermesDesktop.mcpOauth?.cancel(listener.current)
      const result = await action(verb, request)
      if (current !== generation.current) return
      setRequests(items => items.map(item => (item.id === request.id ? result.request : item)))
      setError('')
    } catch {
      if (current === generation.current) setError('The bot could not confirm this sign-in action. Refresh and retry.')
    }
  }

  if (!requests.length && !error) return null
  return (
    <div className="max-h-[50vh] space-y-3 overflow-y-auto px-4 py-3" aria-label="Bot sign-in requests">
      {requests.map(request => (
        <section
          key={request.id}
          className="rounded-xl border bg-background p-4 text-sm"
          aria-label={`Sign in to ${request.name}`}
        >
          <div className="font-semibold">Sign in · {request.name}</div>
          <p className="mt-1 text-xs text-muted-foreground">This chat · {request.owner_profile}</p>
          <p className="mt-2">{request.detail}</p>
          <p className="mt-2 text-muted-foreground">
            {request.scopes.length
              ? `Permissions: ${request.scopes.join(', ')}`
              : 'Review the requested permissions on the provider consent screen.'}
          </p>
          {request.account_ref && (
            <p className="mt-1 text-xs text-muted-foreground">Account slot: {request.account_ref}</p>
          )}
          {request.user_code && (
            <>
              <p className="my-3 select-text font-mono text-xl">{request.user_code}</p>
              <p>Enter this code only for the sign-in you requested for this bot.</p>
            </>
          )}
          <div className="mt-3 flex gap-3">
            {request.status === 'authorized' ? (
              request.continued ? (
                <p>Task continuation submitted</p>
              ) : (
                <button
                  className="rounded-lg bg-primary px-3 py-2 text-primary-foreground"
                  onClick={() => void respond('continue', request)}
                >
                  Confirm account and continue task
                </button>
              )
            ) : (
              <>
                <button
                  className="rounded-lg bg-primary px-3 py-2 text-primary-foreground"
                  disabled={working}
                  onClick={() => void signIn(request)}
                >
                  {['failed', 'expired', 'canceled'].includes(request.status) ? 'Retry sign-in' : 'Sign in'}
                </button>
                <button className="rounded-lg border px-3 py-2" onClick={() => void respond('cancel', request)}>
                  Cancel
                </button>
              </>
            )}
          </div>
          <p className="mt-3 text-xs text-muted-foreground">
            API authorization stays on this bot. For other website logins, use this bot's VM controls.
          </p>
        </section>
      ))}
      {working && <p role="status">Waiting for secure sign-in…</p>}
      {error && <p role="alert">{error}</p>}
    </div>
  )
}
