import type { FromSwift, ToSwift, WebAPI } from './protocol'

type Handler = { postMessage(msg: unknown): Promise<unknown> }

declare global {
  interface Window {
    webkit?: { messageHandlers?: { bridge?: Handler } }
    __nbm?: WebAPI
  }
}

export const isNative = () => Boolean(window.webkit?.messageHandlers?.bridge)

/** Send a message to Swift. Resolves with Swift's reply. Outside the app (vite dev) it hits the mock. */
export async function send<T = unknown>(msg: ToSwift): Promise<T> {
  const handler = window.webkit?.messageHandlers?.bridge
  if (handler) return (await handler.postMessage(msg)) as T
  const { mockSend } = await import('./mock')
  return (await mockSend(msg)) as T
}

export function installWebAPI(api: WebAPI) {
  window.__nbm = api
}

export type { FromSwift, ToSwift }
