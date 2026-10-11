import { afterEach, expect, it } from 'vitest'

import { $subagentsBySession, reconcileSubagentSnapshot, upsertSubagent } from './subagents'

afterEach(() => $subagentsBySession.set({}))
it('restores bounded results, terminal time and backend control capabilities from the owned snapshot', () => {
  reconcileSubagentSnapshot('owner', [
    {
      subagent_id: 'finished',
      parent_id: 'parent',
      goal: 'Review files',
      status: 'completed',
      summary: 'Result\nwith evidence',
      started_at: 100,
      completed_at: 104,
      can_steer: false,
      can_interrupt: false,
      can_tail: true
    }
  ])
  expect($subagentsBySession.get().owner[0]).toMatchObject({
    parentId: 'parent',
    status: 'completed',
    summary: 'Result\nwith evidence',
    startedAt: 100000,
    updatedAt: 104000,
    durationSeconds: 4,
    canSteer: false,
    canInterrupt: false,
    canTail: true
  })
})
it('hydrates last tool activity without claiming it is active and preserves stream history on refresh', () => {
  const child = {
    subagent_id: 'worker',
    goal: 'Actual worker',
    status: 'running',
    started_at: 1001,
    last_tool: 'read_file'
  }

  reconcileSubagentSnapshot('owner', [child])
  const first = $subagentsBySession.get().owner
  expect(first[0].stream).toMatchObject([{ kind: 'tool', text: 'Read File' }])
  expect(first[0].currentTool).toBeUndefined()
  expect(first[0].startedAt).toBe(child.started_at * 1000)
  reconcileSubagentSnapshot('owner', [child])
  expect($subagentsBySession.get().owner).toBe(first)
  upsertSubagent('other', { subagent_id: 'worker', goal: 'Other owner' })
  const other = $subagentsBySession.get().other
  upsertSubagent('owner', { subagent_id: 'worker', text: 'New progress' }, false, 'subagent.progress')
  const stream = $subagentsBySession.get().owner[0].stream
  reconcileSubagentSnapshot('owner', [child])
  expect($subagentsBySession.get().owner[0].stream).toBe(stream)
  reconcileSubagentSnapshot('owner', [])
  expect($subagentsBySession.get().owner).toEqual([])
  expect($subagentsBySession.get().other).toBe(other)
})
