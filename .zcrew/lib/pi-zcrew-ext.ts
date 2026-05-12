/**
 * pi-native zcrew extension — replaces pi-mcp-adapter + zcrew MCP server.
 *
 * Tool surface is gated by BX_INSIDE:
 *   worker (BX_INSIDE=1): no tools; auto-reply via agent_end
 *   orchestrator (unset): zcrew_send, zcrew_list
 *
 * All tools shell out to the zcrew CLI.
 */
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { execFile, execFileSync } from "node:child_process";
import { promisify } from "node:util";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { accessSync, constants, realpathSync, statSync } from "node:fs";

const execFileAsync = promisify(execFile);

// ---------------------------------------------------------------------------
// zcrew binary resolution
// ---------------------------------------------------------------------------

const __dirname = dirname(fileURLToPath(import.meta.url));

function isExecutableFile(p: string): boolean {
  try {
    return statSync(p).isFile() && (accessSync(p, constants.X_OK), true);
  } catch {
    return false;
  }
}

function resolveZcrewBin(): string {
  const override = process.env.ZCREW_BIN;
  if (override) {
    if (isExecutableFile(override)) return realpathSync(override);
    throw new Error(`ZCREW_BIN is set but not executable: ${override}`);
  }

  const sibling = resolve(__dirname, "../bin/zcrew");
  if (isExecutableFile(sibling)) return realpathSync(sibling);

  try {
    const found = execFileSync("bash", ["-lc", "command -v zcrew"], {
      encoding: "utf8",
    }).trim();
    if (found && isExecutableFile(found)) return realpathSync(found);
  } catch {}

  throw new Error(
    "zcrew binary not found (checked ZCREW_BIN, local ../bin/zcrew, and PATH)",
  );
}

const ZCREW_BIN = resolveZcrewBin();

// ---------------------------------------------------------------------------
// Shell-out helper
// ---------------------------------------------------------------------------

async function runZcrew(args: string[]): Promise<string> {
  const { stdout, stderr } = await execFileAsync(ZCREW_BIN, args);
  const parts = [stdout.trim(), stderr.trim()].filter(Boolean);
  return parts.join("\n") || "(no output)";
}

async function runZcrewChecked(args: string[]): Promise<string> {
  try {
    return await runZcrew(args);
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    const parts = [(e.stdout || "").trim(), (e.stderr || "").trim()].filter(
      Boolean,
    );
    throw new Error(parts.join("\n") || e.message || String(err));
  }
}

// ---------------------------------------------------------------------------
// Pure arg builders (unit-testable)
// ---------------------------------------------------------------------------

export function replyArgs(p: { message: string }): string[] {
  return ["reply", p.message];
}

export function sendArgs(p: {
  name: string;
  message: string;
  compact?: boolean;
}): string[] {
  const args = ["send"];
  if (p.compact) args.push("--compact");
  args.push(p.name, p.message);
  return args;
}

export function listArgs(): string[] {
  return ["list", "--json"];
}

// ---------------------------------------------------------------------------
// Extension factory
// ---------------------------------------------------------------------------

type PiContentPart = { type?: string; text?: string };
type PiAgentMessage = {
  role?: string;
  stopReason?: string;
  content?: PiContentPart[];
};
type PiAgentEndEvent = { messages?: PiAgentMessage[] };

export default function (pi: ExtensionAPI): void {
  const isWorker = Boolean(process.env.BX_INSIDE);

  if (isWorker) {
    // Worker path: auto-fire reply on agent_end.
    pi.on("agent_end", async (event: PiAgentEndEvent) => {
      const messages = event.messages ?? [];
      for (let i = messages.length - 1; i >= 0; i--) {
        const msg = messages[i];
        if (msg?.role !== "assistant") continue;
        if (msg.stopReason === "aborted" && !(msg.content?.length)) continue;
        const text = (msg.content ?? [])
          .filter((c) => c?.type === "text" && typeof c.text === "string")
          .map((c) => c.text ?? "")
          .join("")
          .trim();
        if (!text) continue;
        await runZcrew(replyArgs({ message: text })).catch(() => {});
        return;
      }
    });
  } else {
    // ---- Orchestrator: zcrew_send + zcrew_list ----
    pi.registerTool({
      name: "zcrew_send",
      label: "zcrew send",
      description:
        "Send a message to a registered worker pane by name. " +
        "Orchestrator-only. Set compact=true to inject /compact " +
        "before delivery (use when starting a new task on an " +
        "existing agent).",
      parameters: Type.Object({
        name: Type.String({ minLength: 1 }),
        message: Type.String({ minLength: 1 }),
        compact: Type.Optional(Type.Boolean()),
      }),
      async execute(_id, params, _signal, _onUpdate, _ctx) {
        const text = await runZcrewChecked(sendArgs(params));
        return { content: [{ type: "text", text }] };
      },
    });

    pi.registerTool({
      name: "zcrew_list",
      label: "zcrew list",
      description: "Return the pane registry as JSON.",
      parameters: Type.Object({}),
      async execute(_id, _params, _signal, _onUpdate, _ctx) {
        const text = await runZcrewChecked(listArgs());
        return { content: [{ type: "text", text }] };
      },
    });
  }
}
