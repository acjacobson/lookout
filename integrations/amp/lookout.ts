// Lookout plugin for Amp: reports turn starts and finished turns to the Lookout
// menu bar app through ~/.lookout/bin/lookout-report.
//
// Amp has no event for "waiting for approval", so Amp rows only ever show
// "working" and "done".
import type { PluginAPI } from '@ampcode/plugin'
import { spawn } from 'node:child_process'

export const description = 'Reports finished Amp turns to the Lookout menu bar app'

const REPORTER = `${process.env.HOME}/.lookout/bin/lookout-report`

function report(state: string, payload: Record<string, unknown>) {
  try {
    // The payload goes over stdin, never into a shell command line.
    const child = spawn(REPORTER, ['amp', state], { stdio: ['pipe', 'ignore', 'ignore'] })
    child.on('error', () => {})
    child.stdin?.end(JSON.stringify(payload))
  } catch {
    // Never let Lookout break an Amp turn.
  }
}

function workspace(amp: PluginAPI): string | undefined {
  try {
    const root = (amp as any).system?.workspaceRoot
    return root ? (amp as any).helpers?.filePathFromURI?.(root) : undefined
  } catch {
    return undefined
  }
}

function title(ctx: any): string | undefined {
  try {
    const t = ctx?.thread?.title?.get?.()
    return typeof t === 'string' ? t : undefined
  } catch {
    return undefined
  }
}

export default function (amp: PluginAPI) {
  amp.on('agent.start', async (event: any, ctx: any) => {
    report('prompt', {
      thread_id: event.thread?.id,
      prompt: event.message,
      title: title(ctx),
      cwd: workspace(amp),
    })
  })

  amp.on('agent.end', async (event: any, ctx: any) => {
    report('done', {
      thread_id: event.thread?.id,
      title: title(ctx),
      cwd: workspace(amp),
      status: event.status,
      summary: event.status === 'done' ? undefined : `Turn ended: ${event.status}`,
    })
  })
}
