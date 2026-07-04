import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const VALID_STATES = new Set(["blocked", "working", "done", "idle"]);
const DEFAULT_SESSION_PREFIX = "agent-";
let tmuxSession: string | undefined;
let sessionPrefix: string | undefined;

// Absolute path to scripts/status.sh, resolved relative to this extension file
// (extensions/ and scripts/ are siblings in the plugin checkout). Used to prime
// the event-driven status badge after a state change instead of polling.
function statusScriptPath(): string | undefined {
  try {
    const here = dirname(fileURLToPath(import.meta.url));
    return join(here, "..", "scripts", "status.sh");
  } catch {
    return undefined;
  }
}

// triggerStatusRefresh recomputes the cached status badge in the background so
// the event-driven status line updates promptly after a reported state change,
// with no periodic polling. Mirrors trigger_status_refresh() in
// scripts/helpers.sh. Fire-and-forget: `tmux run-shell -b` backgrounds it.
function triggerStatusRefresh() {
  const script = statusScriptPath();
  if (!script) return;
  runTmux(["run-shell", "-b", `${script} --refresh`]);
}

function runTmux(args: string[]): string | undefined {
  try {
    return execFileSync("tmux", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    return undefined;
  }
}

function currentTmuxSession(): string | undefined {
  if (tmuxSession) return tmuxSession;
  const pane = process.env.TMUX_PANE;
  if (!pane) return undefined;
  tmuxSession = runTmux(["display-message", "-p", "-t", pane, "#{session_name}"]);
  return tmuxSession;
}

function managedSessionPrefix(): string {
  if (sessionPrefix === undefined) {
    sessionPrefix =
      runTmux(["show-option", "-gqv", "@agent_session_prefix"]) ||
      DEFAULT_SESSION_PREFIX;
  }
  return sessionPrefix;
}

// isWatchedManagedPane reports whether TMUX_PANE belongs to a managed agent
// session (session name carries the configured prefix) that a client is
// currently looking at: the session has an attached client, this pane's window
// is the active window, and this pane is the active pane in it.
//
// tmux can only detect client attachment, not terminal focus, so the check is
// deliberately restricted to managed sessions: those live inside the plugin's
// popup, and closing the popup detaches the client, which makes
// session_attached a reliable "being watched" signal there. For manual panes
// in an always-attached outer session the same signal would be meaningless
// (terminal minimized, popup covering the pane, forgotten second client), so
// they never take this shortcut.
//
// Used to avoid flashing "done" (finished, unseen) when the user is already
// watching the session finish in real time — there is nothing to "see" later,
// so it should read "idle" immediately instead of getting stuck on "done"
// until the session is closed and reopened via the picker/launcher.
//
// NOTE: scripts/helpers.sh mirrors this in Bash as is_watched_managed_pane()
// (with is_pane_visible()), used by scripts/state.sh so agents wired through
// hooks (e.g. Codex's Stop hook) get the same "skip done when watched" shortcut.
// Keep the two implementations in sync when changing this logic.
function isWatchedManagedPane(): boolean {
  const session = currentTmuxSession();
  if (!session || !session.startsWith(managedSessionPrefix())) return false;
  return isPaneVisible();
}

function isPaneVisible(): boolean {
  const pane = process.env.TMUX_PANE;
  if (!pane) return false;
  const out = runTmux([
    "display-message",
    "-p",
    "-t",
    pane,
    "#{session_attached} #{window_active} #{pane_active}",
  ]);
  if (!out) return false;
  const [sessionAttached, windowActive, paneActive] = out.split(" ");
  return sessionAttached !== "0" && windowActive === "1" && paneActive === "1";
}

function setState(state: "blocked" | "working" | "done" | "idle") {
  if (!VALID_STATES.has(state)) return;
  const now = Math.floor(Date.now() / 1000).toString();
  const args: string[] = [];
  const addTmuxCommand = (command: string[]) => {
    if (args.length > 0) args.push(";");
    args.push(...command);
  };

  // Pane-scoped state: works for manual agent panes, where many panes can share
  // one tmux session and a session-level option would collide.
  const pane = process.env.TMUX_PANE;
  if (pane) {
    addTmuxCommand(["set-option", "-p", "-t", pane, "@agent_state", state]);
    addTmuxCommand(["set-option", "-p", "-t", pane, "@agent_state_at", now]);
  }

  // Session-scoped state is authoritative only for managed sessions (one agent
  // per tmux session). Manual panes can share a session, so session-level state
  // there would be last-writer-wins pollution and may leak through tmux format
  // fallback.
  const session = currentTmuxSession();
  if (session && session.startsWith(managedSessionPrefix())) {
    addTmuxCommand(["set-option", "-t", session, "@agent_state", state]);
    addTmuxCommand(["set-option", "-t", session, "@agent_state_at", now]);
  }

  if (args.length > 0) {
    runTmux(args);
    // Refresh the cached status badge now that state changed, so the
    // event-driven status line reflects this report without polling.
    triggerStatusRefresh();
  }
}

export default function piTmuxStateExtension(pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    setState("idle");
  });

  pi.on("agent_start", async () => {
    setState("working");
  });

  pi.on("agent_end", async () => {
    // If the user is actively watching this managed session's pane right now,
    // there is nothing left to "discover" later — go straight to idle instead
    // of done, so the badge does not get stuck showing done while attached.
    // Manual panes always report done (attachment is not a reliable
    // "watching" signal outside the managed popup flow).
    setState(isWatchedManagedPane() ? "idle" : "done");
  });

  pi.on("session_shutdown", async () => {
    setState("idle");
  });
}
