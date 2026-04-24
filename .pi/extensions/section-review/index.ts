import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Editor, Key, matchesKey, truncateToWidth } from "@mariozechner/pi-tui";

type Section = {
  id: string;
  title: string;
  body: string;
};

type ChatEntry = {
  type?: string;
  message?: {
    role?: string;
    content?: unknown;
  };
};

function parseSections(input: string): Section[] {
  const normalized = input.replace(/\r\n/g, "\n").trim();
  if (!normalized) return [];

  const lines = normalized.split("\n");
  const sections: Section[] = [];

  let currentTitle = "Introduction";
  let currentBody: string[] = [];

  const flush = () => {
    const body = currentBody.join("\n").trim();
    sections.push({
      id: `section-${sections.length + 1}`,
      title: currentTitle,
      body,
    });
  };

  for (const line of lines) {
    const heading = line.match(/^(#{1,6})\s+(.*)$/);
    if (heading) {
      if (sections.length > 0 || currentBody.length > 0) {
        flush();
      }
      currentTitle = heading[2].trim() || `Section ${sections.length + 1}`;
      currentBody = [];
    } else {
      currentBody.push(line);
    }
  }

  flush();

  return sections.filter((section) => section.title || section.body);
}

function textFromContent(content: unknown): string {
  if (typeof content === "string") return content;

  if (Array.isArray(content)) {
    return content
      .map((block) => {
        if (
          typeof block === "object"
          && block !== null
          && "type" in block
          && "text" in block
          && (block as { type?: unknown }).type === "text"
          && typeof (block as { text?: unknown }).text === "string"
        ) {
          return (block as { text: string }).text;
        }
        return "";
      })
      .filter(Boolean)
      .join("\n");
  }

  return "";
}

function getLatestAssistantOutput(ctx: { sessionManager: { getBranch: () => ChatEntry[] } }): string | null {
  const entries = ctx.sessionManager.getBranch();

  for (let i = entries.length - 1; i >= 0; i--) {
    const entry = entries[i];
    if (entry?.type !== "message") continue;

    const message = entry.message;
    if (!message || message.role !== "assistant") continue;

    const text = textFromContent(message.content).trim();
    if (text) return text;
  }

  return null;
}

export default function sectionReviewExtension(pi: ExtensionAPI): void {
  pi.registerCommand("section-review", {
    description: "Review latest assistant output one section at a time (→ next, ← back, Enter confirm)",
    handler: async (_args, ctx) => {
      if (!ctx.hasUI) {
        return;
      }

      const source = getLatestAssistantOutput(ctx);
      if (!source) {
        ctx.ui.notify("No assistant output found in current chat branch.", "warning");
        return;
      }

      const sections = parseSections(source);
      if (sections.length === 0) {
        ctx.ui.notify("Latest output has no parsable sections.", "warning");
        return;
      }

      const result = await ctx.ui.custom<Record<string, string> | null>((tui, theme, _keybindings, done) => {
        let index = 0;
        const comments = new Map<string, string>();
        let cachedLines: string[] | undefined;

        const editor = new Editor(tui, {
          borderColor: (s: string) => theme.fg("accent", s),
          selectList: {
            selectedPrefix: (t: string) => theme.fg("accent", t),
            selectedText: (t: string) => theme.fg("accent", t),
            description: (t: string) => theme.fg("muted", t),
            scrollInfo: (t: string) => theme.fg("dim", t),
            noMatch: (t: string) => theme.fg("warning", t),
          },
        });

        const isSubmitTab = () => index === sections.length;
        const currentSection = () => sections[index];

        const setEditorFromCurrent = () => {
          if (isSubmitTab()) return;
          const section = currentSection();
          editor.setText(comments.get(section.id) ?? "");
        };

        const saveCurrent = () => {
          if (isSubmitTab()) return;
          const section = currentSection();
          comments.set(section.id, editor.getText().trim());
        };

        const refresh = () => {
          cachedLines = undefined;
          tui.requestRender();
        };

        const finish = () => {
          const output: Record<string, string> = {};
          for (const section of sections) {
            output[section.title] = comments.get(section.id) ?? "";
          }
          done(output);
        };

        setEditorFromCurrent();

        const handleInput = (data: string) => {
          if (matchesKey(data, Key.escape)) {
            done(null);
            return;
          }

          if (matchesKey(data, Key.right) || matchesKey(data, Key.tab)) {
            saveCurrent();
            index = Math.min(sections.length, index + 1);
            setEditorFromCurrent();
            refresh();
            return;
          }

          if (matchesKey(data, Key.left) || matchesKey(data, Key.shift("tab"))) {
            saveCurrent();
            index = Math.max(0, index - 1);
            setEditorFromCurrent();
            refresh();
            return;
          }

          if (matchesKey(data, Key.enter) && isSubmitTab()) {
            finish();
            return;
          }

          if (!isSubmitTab()) {
            editor.handleInput(data);
            refresh();
          }
        };

        const render = (width: number): string[] => {
          if (cachedLines) return cachedLines;

          const lines: string[] = [];
          const add = (line: string) => lines.push(truncateToWidth(line, width));

          add(theme.fg("accent", "─".repeat(width)));
          add(
            theme.fg(
              "accent",
              ` Section Review (${Math.min(index + 1, sections.length + 1)}/${sections.length + 1})`,
            ),
          );
          lines.push("");

          if (isSubmitTab()) {
            add(theme.fg("success", " Confirm all comments"));
            lines.push("");
            for (const section of sections) {
              const comment = comments.get(section.id)?.trim();
              const renderedComment = comment ? comment : theme.fg("dim", "(no comment)");
              add(theme.fg("muted", ` • ${section.title}: `) + renderedComment);
            }
            lines.push("");
            add(theme.fg("dim", " Enter confirm • ← back • Esc cancel"));
          } else {
            const section = currentSection();
            add(theme.bold(theme.fg("text", ` ${section.title}`)));
            lines.push("");

            const previewLines = (section.body || "(empty section)").split("\n");
            const visiblePreview = previewLines.slice(0, 8);
            for (const preview of visiblePreview) {
              add(theme.fg("muted", ` ${preview}`));
            }
            if (previewLines.length > visiblePreview.length) {
              add(theme.fg("dim", " …"));
            }

            lines.push("");
            add(theme.fg("text", " Comment:"));
            for (const editorLine of editor.render(width - 2)) {
              add(` ${editorLine}`);
            }
            lines.push("");
            add(theme.fg("dim", " → next • ← previous • Tab/Shift+Tab • Esc cancel"));
          }

          add(theme.fg("accent", "─".repeat(width)));

          cachedLines = lines;
          return lines;
        };

        return {
          render,
          handleInput,
          invalidate: () => {
            cachedLines = undefined;
          },
        };
      });

      if (!result) {
        ctx.ui.notify("Section review cancelled", "info");
        return;
      }

      const summary = Object.entries(result)
        .map(([title, comment]) => `### ${title}\n${comment || "(no comment)"}`)
        .join("\n\n");

      ctx.ui.setEditorText(summary);
      ctx.ui.notify("Review complete. Summary inserted into editor.", "success");
    },
  });
}
