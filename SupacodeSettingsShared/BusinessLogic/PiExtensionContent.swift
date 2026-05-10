/// Bundled TypeScript extension that Supacode installs into
/// `~/.pi/agent/extensions/supacode/index.ts` to report agent
/// lifecycle hooks back to the Supacode macOS app.
nonisolated enum PiExtensionContent {
  /// Directory name under `~/.pi/agent/extensions/`.
  static let extensionDirectoryName = "supacode"

  /// Marker comment used to identify Supacode-managed extensions.
  static let ownershipMarker = "/* supacode-managed-extension */"

  static let indexTs = """
    \(ownershipMarker)
    /**
     * Supacode ↔ Pi integration extension.
     *
     * Reports agent lifecycle hooks back to Supacode via the Unix domain socket
     * it injects into every managed terminal session, matching the semantics of
     * the existing Claude and Codex hook integrations.
     *
     * Required env vars (injected automatically by Supacode):
     *   SUPACODE_SOCKET_PATH  — path to the Unix domain socket
     *   SUPACODE_WORKTREE_ID  — worktree identifier
     *   SUPACODE_TAB_ID       — tab UUID
     *   SUPACODE_SURFACE_ID   — terminal surface UUID
     *
     * Hook event mapping:
     *   extension load      → session_start  (agent presence badge)
     *   Pi agent_start      → busy           (UserPromptSubmit equivalent)
     *   Pi agent_end        → idle           (Stop equivalent — resets activity)
     *                       → notification with last_assistant_message
     *   Pi session_shutdown → session_end    (SessionEnd equivalent)
     *                       → idle           (defensive activity reset)
     */

    import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
    import { createConnection } from "node:net";

    interface SupacodeEnv {
      socketPath: string;
      worktreeId: string;
      tabId: string;
      surfaceId: string;
    }

    interface HookPayload {
      hook_event_name: string;
      title?: string;
      message?: string;
      last_assistant_message?: string;
    }

    function readSupacodeEnv(): SupacodeEnv | null {
      const socketPath = process.env["SUPACODE_SOCKET_PATH"];
      const worktreeId = process.env["SUPACODE_WORKTREE_ID"];
      const tabId = process.env["SUPACODE_TAB_ID"];
      const surfaceId = process.env["SUPACODE_SURFACE_ID"];

      if (!socketPath || !worktreeId || !tabId || !surfaceId) return null;
      return { socketPath, worktreeId, tabId, surfaceId };
    }

    /**
     * Sends raw bytes to a Unix domain socket and closes the connection.
     * Times out after 1 s (Pi serializes hook callbacks, so a stalled
     * delivery would stall the agent) and swallows all errors —
     * hook delivery is best-effort.
     */
    function sendToSocket(socketPath: string, data: Buffer): Promise<void> {
      return new Promise<void>((resolve) => {
        let settled = false;
        const done = () => {
          if (!settled) {
            settled = true;
            resolve();
          }
        };

        const client = createConnection({ path: socketPath });
        const timer = setTimeout(() => {
          client.destroy();
          done();
        }, 1000);

        client.on("connect", () => {
          client.write(data, () => {
            client.end();
            clearTimeout(timer);
            done();
          });
        });

        client.on("error", () => {
          clearTimeout(timer);
          done();
        });
      });
    }

    function sendNotification(env: SupacodeEnv, payload: HookPayload): Promise<void> {
      const header = `${env.worktreeId} ${env.tabId} ${env.surfaceId} pi\\n`;
      const body = JSON.stringify(payload) + "\\n";
      return sendToSocket(env.socketPath, Buffer.from(header + body, "utf8"));
    }

    /**
     * Sends a hook event (session lifecycle or per-turn activity) using
     * the same JSON envelope every other agent emits.
     */
    function sendEvent(env: SupacodeEnv, eventName: string): Promise<void> {
      const envelope = {
        event: eventName,
        v: 1,
        agent: "pi",
        surface_id: env.surfaceId,
        pid: process.pid,
      };
      const body = JSON.stringify(envelope) + "\\n";
      return sendToSocket(env.socketPath, Buffer.from(body, "utf8"));
    }

    function lastAssistantText(ctx: { sessionManager: { getEntries(): any[] } }): string | undefined {
      const entries = ctx.sessionManager.getEntries();
      for (let i = entries.length - 1; i >= 0; i--) {
        const entry = entries[i];
        if (entry.type !== "message") continue;
        if (entry.message.role !== "assistant") continue;

        const content = entry.message.content;
        if (!Array.isArray(content)) continue;

        const text = content
          .filter((c: { type: string; text?: string }) => c.type === "text" && typeof c.text === "string")
          .map((c: { text: string }) => c.text)
          .join("")
          .trim();

        if (text.length > 0) return text;
      }
      return undefined;
    }

    export default function (pi: ExtensionAPI) {
      const env = readSupacodeEnv();

      // Not running under Supacode — skip lifecycle hooks.
      if (!env) return;

      // Extension load = agent process running. Pi has no equivalent of
      // Claude's SessionStart hook, so we fire it ourselves.
      void sendEvent(env, "session_start");

      pi.on("agent_start", async (_event, _ctx) => {
        await sendEvent(env, "busy");
      });

      pi.on("agent_end", async (_event, ctx) => {
        // Atomic state-set: `idle` overwrites whatever was running on the
        // Supacode side — turn-level Stop equivalent.
        await sendEvent(env, "idle");

        const lastMessage = lastAssistantText(ctx);
        await sendNotification(env, {
          hook_event_name: "Stop",
          last_assistant_message: lastMessage,
        });
      });

      pi.on("session_shutdown", async (_event, _ctx) => {
        await sendEvent(env, "session_end");
        await sendEvent(env, "idle");
      });
    }
    """
}
