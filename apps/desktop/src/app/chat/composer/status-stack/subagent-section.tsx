import { useState } from 'react'

import { SubagentRow } from '@/app/agents'
import { ActivityTimerText } from '@/components/chat/activity-timer-text'
import { StatusRow } from '@/components/chat/status-row'
import { StatusSection } from '@/components/chat/status-section'
import { Codicon } from '@/components/ui/codicon'
import { GlyphSpinner } from '@/components/ui/glyph-spinner'
import { useViewedInterval } from '@/hooks/use-viewed-interval'
import { useI18n } from '@/i18n'
import { useSessionSlice } from '@/lib/use-session-slice'
import { $subagentsBySession, buildSubagentTree, type SubagentNode, type SubagentProgress } from '@/store/subagents'

import { SubagentControls } from './subagent-controls'
import { SubagentTranscript } from './subagent-transcript'

interface SubagentSectionProps {
  sessionId: string
}

const rosterRows = (nodes: SubagentNode[], depth = 0): { item: SubagentNode; depth: number }[] =>
  nodes.flatMap(item => [{ item, depth }, ...rosterRows(item.children, depth + 1)])

/** A composer-local roster: never borrow the global Agents panel's scope. */
export function SubagentSection({ sessionId }: SubagentSectionProps) {
  const { t } = useI18n()
  const items = useSessionSlice($subagentsBySession, sessionId)
  const live = items.filter(item => item.status === 'running' || item.status === 'queued')
  const [nowMs, setNowMs] = useState(Date.now)
  const [selected, setSelected] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const hasLive = live.length > 0
  const rows = rosterRows(buildSubagentTree(items))

  const labels = {
    completed: t.agents.done,
    failed: t.agents.failed,
    interrupted: t.agents.interrupted,
    queued: t.agents.queued,
    running: t.agents.running
  }

  useViewedInterval(() => setNowMs(Date.now()), 1000, hasLive)

  if (items.length === 0) {
    return null
  }

  const row = (item: SubagentProgress, depth: number) => (
    <StatusRow
      depth={depth}
      expanded={selected === item.id}
      key={item.id}
      leading={
        item.status === 'running' || item.status === 'queued' ? (
          <GlyphSpinner
            ariaLabel={item.status === 'queued' ? t.agents.queued : t.agents.running}
            className="text-(--ui-purple)"
            spinner="braille"
          />
        ) : (
          <Codicon name={item.status === 'completed' ? 'pass' : 'warning'} size="0.8rem" />
        )
      }
      onActivate={() => setSelected(selected === item.id ? null : item.id)}
      trailing={
        <span className="flex shrink-0 items-center gap-2 text-[0.65rem] text-(--ui-text-tertiary)">
          {labels[item.status]}
          {(item.status === 'running' || item.status === 'queued') && (
            <ActivityTimerText
              className="shrink-0 text-[0.65rem]"
              seconds={Math.max(0, Math.floor((nowMs - item.startedAt) / 1000))}
            />
          )}
        </span>
      }
      trailingVisible
    >
      <span className="min-w-0 flex-1">
        <span className="block truncate text-xs text-(--ui-text-primary)">{item.goal}</span>
        <span className="block truncate text-[0.68rem] text-(--ui-text-tertiary)">
          {item.stream.at(-1)?.text ||
            item.summary ||
            (item.status === 'queued' ? t.agents.queued : t.agents.waitingActivity)}
        </span>
      </span>
    </StatusRow>
  )

  const detail = items.find(item => item.id === selected)
  const detailLive = detail?.status === 'running' || detail?.status === 'queued'

  return (
    <div className="composer-no-drag min-w-0" data-slot="composer-subagents">
      <StatusSection
        collapsedIndicator={
          hasLive ? (
            <GlyphSpinner
              ariaLabel={live.some(item => item.status === 'running') ? t.agents.running : t.agents.queued}
              className="text-(--ui-purple)"
              spinner="braille"
            />
          ) : undefined
        }
        icon={<Codicon className="text-(--ui-purple)" name="agent" size="0.8rem" />}
        label={t.statusStack.subagents(items.length)}
      >
        <div className="max-h-[25vh] overflow-y-auto overscroll-y-auto">
          {rows.map(({ item, depth }) => row(item, depth))}
        </div>
        {detail && (
          <div
            className="status-subagent-detail max-h-[25vh] overflow-y-auto overscroll-y-auto pr-3 py-2"
            data-slot="composer-subagent-detail"
          >
            {detailLive && (detail.canSteer !== false || detail.canInterrupt !== false) && (
              <SubagentControls
                canInterrupt={detail.canInterrupt}
                canSteer={detail.canSteer}
                key={`${sessionId}:${detail.id}`}
                sessionId={sessionId}
                setText={text => setDrafts(previous => ({ ...previous, [detail.id]: text }))}
                subagentId={detail.id}
                text={drafts[detail.id] ?? ''}
              />
            )}
            <SubagentRow node={{ ...detail, children: [] }} nowMs={nowMs} />
            {detail.canTail !== false && (
              <SubagentTranscript
                key={`tail:${sessionId}:${detail.id}`}
                live={detailLive}
                sessionId={sessionId}
                subagentId={detail.id}
              />
            )}
          </div>
        )}
      </StatusSection>
    </div>
  )
}
