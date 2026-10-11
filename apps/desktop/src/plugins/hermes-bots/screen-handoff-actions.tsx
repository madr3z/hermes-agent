import { Button, Codicon, Tip } from '@hermes/plugin-sdk'

import type { ScreenTaskContinuation } from './screen-continuation'

interface ScreenHandoffActionsProps {
  iHold: boolean
  humanOther: boolean
  busy: boolean
  canTakeOver: boolean
  task: ScreenTaskContinuation | null
  continuationPending: boolean
  text: { handBack: string; handBackForce: string; handBackForceHint: string; takeOver: string }
  handBack: (force?: boolean, continueTask?: boolean) => Promise<void>
  takeOver: () => Promise<void>
}

export function ScreenHandoffActions({
  iHold,
  humanOther,
  busy,
  canTakeOver,
  task,
  continuationPending,
  text,
  handBack,
  takeOver
}: ScreenHandoffActionsProps) {
  return (
    <>
      {iHold ? (
        <>
          <Button disabled={busy} onClick={() => void handBack()} size="sm" variant="secondary">
            <Codicon name="debug-continue" /> {text.handBack}
          </Button>
          {task && (
            <Button disabled={busy} onClick={() => void handBack(false, true)} size="sm">
              Hand back and continue task
            </Button>
          )}
        </>
      ) : (
        <>
          {humanOther && (
            <Tip label={text.handBackForceHint}>
              <Button disabled={busy} onClick={() => void handBack(true)} size="sm" variant="secondary">
                <Codicon name="debug-continue" /> {text.handBackForce}
              </Button>
            </Tip>
          )}
          <Button disabled={busy || continuationPending || !canTakeOver} onClick={() => void takeOver()} size="sm">
            <Codicon name="record-keys" /> {text.takeOver}
          </Button>
        </>
      )}
      {continuationPending && !iHold && task && (
        <Button disabled={busy} onClick={() => void handBack(false, true)} size="sm">
          {task.submissionStarted ? 'Return to chat' : 'Retry hand back'}
        </Button>
      )}
    </>
  )
}
