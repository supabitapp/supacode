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
     *   Pi agent_start      → busy = 1       (UserPromptSubmit equivalent)
     *   Pi agent_end        → busy = 0       (Stop equivalent)
     *                       → notification with last_assistant_message
     *   Pi session_shutdown → busy = 0       (SessionEnd equivalent)
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

    function sendBusy(env: SupacodeEnv, active: boolean): Promise<void> {
      const flag = active ? "1" : "0";
      const message = `${env.worktreeId} ${env.tabId} ${env.surfaceId} ${flag}\\n`;
      return sendToSocket(env.socketPath, Buffer.from(message, "utf8"));
    }

    function sendNotification(env: SupacodeEnv, payload: HookPayload): Promise<void> {
      const header = `${env.worktreeId} ${env.tabId} ${env.surfaceId} pi\\n`;
      const body = JSON.stringify(payload) + "\\n";
      return sendToSocket(env.socketPath, Buffer.from(header + body, "utf8"));
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

      pi.on("agent_start", async (_event, _ctx) => {
        await sendBusy(env, true);
      });

      pi.on("agent_end", async (_event, ctx) => {
        await sendBusy(env, false);

        const lastMessage = lastAssistantText(ctx);
        await sendNotification(env, {
          hook_event_name: "Stop",
          last_assistant_message: lastMessage,
        });
      });

      pi.on("session_shutdown", async (_event, _ctx) => {
        await sendBusy(env, false);
      });
    }
    """
}
