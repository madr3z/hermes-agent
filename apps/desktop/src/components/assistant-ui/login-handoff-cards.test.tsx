import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import type { HermesGateway } from '@/hermes'
import { LoginHandoffCards, type LoginHandoffRequest } from './login-handoff-cards'

const request: LoginHandoffRequest = {
  id: 'owned-request',
  provider: 'mcp',
  name: 'linear',
  owner_profile: 'assistant',
  scopes: ['read'],
  status: 'awaiting_human',
  detail: 'Authorize Linear',
  account_ref: 'linear',
  user_code: '',
  verification_url: '',
  auth_url: '',
  expires_at: 9999999999,
  continued: false
}
afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

it('opens system browser and relays callback only to its owning chat', async () => {
  let started = false
  const rpc = vi.fn(async (method: string) => {
    if (method === 'login.handoff.list')
      return {
        requests: [
          {
            ...request,
            auth_url: started
              ? 'https://linear.app/oauth/authorize?state=opaque&redirect_uri=http%3A%2F%2F127.0.0.1%3A12345%2Fcallback'
              : ''
          }
        ]
      }
    if (method === 'login.handoff.start') started = true
    return { request }
  })
  const openExternal = vi.fn(async () => {})
  Object.defineProperty(window, 'hermesDesktop', {
    configurable: true,
    value: {
      openExternal,
      mcpOauth: {
        listen: vi.fn(async () => ({ id: 'listener', redirectUri: 'http://127.0.0.1:12345/callback' })),
        wait: vi.fn(async () => ({ code: 'PRIVATE-CODE', state: 'opaque', error: null, iss: null })),
        cancel: vi.fn(async () => {})
      }
    }
  })
  render(<LoginHandoffCards gateway={{ request: rpc } as unknown as HermesGateway} sessionId="owned-chat" />)
  fireEvent.click(await screen.findByRole('button', { name: 'Sign in' }))
  await waitFor(() =>
    expect(rpc).toHaveBeenCalledWith(
      'login.handoff.callback',
      expect.objectContaining({
        session_id: 'owned-chat',
        request_id: 'owned-request',
        code: 'PRIVATE-CODE',
        state: 'opaque'
      })
    )
  )
  expect(openExternal).toHaveBeenCalledWith(expect.stringContaining('https://linear.app/oauth/authorize'))
  expect(screen.queryByText('PRIVATE-CODE')).toBeNull()
  expect(screen.getByText('This chat · assistant')).toBeTruthy()
})

it('refuses a provider URL with credentials before launching the browser', async () => {
  let started = false
  const rpc = vi.fn(async (method: string) => {
    if (method === 'login.handoff.list')
      return { requests: [{ ...request, auth_url: started ? 'https://user:password@linear.app/oauth/authorize' : '' }] }
    if (method === 'login.handoff.start') started = true
    return { request }
  })
  const openExternal = vi.fn(async () => {})
  Object.defineProperty(window, 'hermesDesktop', {
    configurable: true,
    value: {
      openExternal,
      mcpOauth: {
        listen: vi.fn(async () => ({ id: 'listener', redirectUri: 'http://127.0.0.1:12345/callback' })),
        cancel: vi.fn(async () => {})
      }
    }
  })
  render(<LoginHandoffCards gateway={{ request: rpc } as unknown as HermesGateway} sessionId="owned-chat" />)
  fireEvent.click(await screen.findByRole('button', { name: 'Sign in' }))
  expect((await screen.findByRole('alert')).textContent).toContain('secure sign-in URL')
  expect(openExternal).not.toHaveBeenCalled()
})

it('retires the exact attempt when opening the browser fails', async () => {
  let started = false
  const rpc = vi.fn(async (method: string) => {
    if (method === 'login.handoff.list')
      return {
        requests: [
          {
            ...request,
            attempt_id: 'attempt-a',
            auth_url: started
              ? 'https://linear.app/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A12345%2Fcallback'
              : ''
          }
        ]
      }
    if (method === 'login.handoff.start') started = true
    return { request: { ...request, attempt_id: 'attempt-a' } }
  })
  const wait = vi.fn(),
    cancel = vi.fn(async () => {})
  Object.defineProperty(window, 'hermesDesktop', {
    configurable: true,
    value: {
      openExternal: vi.fn(async () => {
        throw new Error('browser unavailable')
      }),
      mcpOauth: {
        listen: vi.fn(async () => ({ id: 'listener', redirectUri: 'http://127.0.0.1:12345/callback' })),
        wait,
        cancel
      }
    }
  })
  render(<LoginHandoffCards gateway={{ request: rpc } as unknown as HermesGateway} sessionId="owned-chat" />)
  fireEvent.click(await screen.findByRole('button', { name: 'Sign in' }))
  expect((await screen.findByRole('alert')).textContent).toContain('browser unavailable')
  expect(rpc).toHaveBeenCalledWith('login.handoff.cancel', {
    session_id: 'owned-chat',
    request_id: request.id,
    attempt_id: 'attempt-a'
  })
  expect(wait).not.toHaveBeenCalled()
  expect(cancel).toHaveBeenCalledWith('listener')
})
