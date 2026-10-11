import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, expect, it, vi } from 'vitest'

import { $subagentsBySession, reconcileSubagentSnapshot, upsertSubagent } from '@/store/subagents'

import { ComposerStatusStack } from './index'

vi.mock('@/lib/use-enter-animation', () => ({ useEnterAnimation: () => undefined }))
vi.stubGlobal(
  'ResizeObserver',
  class {
    disconnect() {}
    observe() {}
    unobserve() {}
  }
)

afterEach(() => {
  cleanup()
  $subagentsBySession.set({})
})

it('keeps the selected result in its parent chat after completion and removes live controls', () => {
  upsertSubagent('owner', { subagent_id: 'worker', goal: 'Review source', status: 'running' })

  const view = render(
    <MemoryRouter>
      <ComposerStatusStack queue={null} sessionId="owner" />
    </MemoryRouter>
  )

  fireEvent.click(screen.getByRole('button', { name: /1 Subagent/ }))
  fireEvent.click(screen.getByRole('button', { name: /Review source/ }))
  expect(screen.getByRole('textbox')).toBeTruthy()
  const result = 'Complete result\n\n' + 'Important evidence. '.repeat(40)
  act(() =>
    upsertSubagent('owner', { subagent_id: 'worker', status: 'completed', summary: result }, false, 'subagent.complete')
  )
  expect(view.container.querySelector('[data-slot="subagent-result"]')?.textContent).toBe(result)
  expect(screen.queryByRole('textbox')).toBeNull()
  expect(screen.queryByRole('button', { name: 'Stop' })).toBeNull()
  view.rerender(
    <MemoryRouter>
      <ComposerStatusStack queue={null} sessionId="other" />
    </MemoryRouter>
  )
  expect(view.container.querySelector('[data-slot="subagent-result"]')).toBeNull()
})

it('hydrates completed parent and child rows with truthful controls and a visible hierarchy', () => {
  reconcileSubagentSnapshot('owner', [
    {
      subagent_id: 'parent',
      goal: 'Review project',
      status: 'completed',
      summary: 'Parent result',
      started_at: 100,
      completed_at: 105,
      can_steer: false,
      can_interrupt: false,
      can_tail: false
    },
    {
      subagent_id: 'child',
      parent_id: 'parent',
      goal: 'Check files',
      status: 'interrupted',
      error: 'Runtime restarted',
      started_at: 101,
      completed_at: 104,
      can_steer: false,
      can_interrupt: false,
      can_tail: false
    }
  ])

  const view = render(
    <MemoryRouter>
      <ComposerStatusStack queue={null} sessionId="owner" />
    </MemoryRouter>
  )

  fireEvent.click(screen.getByRole('button', { name: /2 Subagents/ }))
  expect(screen.getByRole('button', { name: /Check files/ }).style.getPropertyValue('--status-row-depth')).toBe('1')
  fireEvent.click(screen.getByRole('button', { name: /Check files/ }))
  expect(view.container.querySelector('[data-slot="subagent-result"]')?.textContent).toBe('Runtime restarted')
  expect(screen.queryByRole('textbox')).toBeNull()
  expect(view.container.querySelector('[data-slot="subagent-transcript"]')).toBeNull()
})
