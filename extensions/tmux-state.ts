import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEFAULT_SESSION_PREFIX = "agent-";
let tmuxSession: string | undefined;
let sessionPrefix: string | undefined;

// Absolute path to scripts/status.sh. Prefer the tmux option exported by the
// plugin: it stays correct even when this extension is loaded through a symlink
// under ~/.pi/agent/extensions. Fall back to the checkout-relative location for
// direct `pi -e /path/to/extensions/tmux-state.ts` usage.
function statusScriptPath(): string | undefined {
  const configured = runTmux(["show-option", "-gqv", "@agent_status_script"]);
  if (configured && existsSync(configured)) return configured;

  try {
    const here = dirname(realpathSync(fileURLToPath(import.meta.url)));
    const candidate = join(here, "..", "scripts", "status.sh");
    return existsSync(candidate) ? candidate : undefined;
  } catch {
    return undefined;
  }
}

// triggerStatusRefresh recomputes the cached status badge in the background so
// the event-driven status line updates promptly after a reported state change,
// with no periodic polling. Mirrors trigger_status_refresh() in
// scripts/helpers.sh. Fire-and-forget: `tmux run-shell -b` backgrounds it.
// Gated on @agent_status being enabled so users who never turned on the badge
// pay nothing (no fork of status.sh --refresh, no refresh-client) on every
// reported state change.
function triggerStatusRefresh() {
  const script = statusScriptPath();
  if (!script) return;
  const status = runTmux(["show-option", "-gqv", "@agent_status"]);
  // The badge defaults to on (agents_session_manager.tmux reads it with a
  // default of 'on'), so skip only when explicitly disabled. Mirrors
  // trigger_status_refresh() in scripts/helpers.sh.
  if (status === "off") return;
  // run-shell passes its argument to a shell: quote the script path so plugin
  // installs under directories with spaces still work.
  const quoted = `'${script.replace(/'/g, `'\\''`)}'`;
  runTmux(["run-shell", "-b", `${quoted} --refresh`]);
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

// isWatchedAgentPane reports whether TMUX_PANE is currently visible to a tmux
// client: the session has an attached client, this pane's window is the active
// window, and this pane is the active pane in it.
//
// Used to avoid flashing "done" (finished, unseen) when the user is already
// watching the turn finish in real time — there is nothing to "see" later, so
// it should read "idle" immediately instead of getting stuck on "done" in the
// right status bar for the current session/pane.
//
// NOTE: scripts/helpers.sh mirrors this in Bash as is_watched_agent_pane()
// (with is_pane_visible()), used by scripts/state.sh so agents wired through
// hooks (e.g. Codex's Stop hook) get the same "skip done when watched" shortcut.
// Keep the two implementations in sync when changing this logic.
function isWatchedAgentPane(): boolean {
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
    if (pane) {
      addTmuxCommand(["set-option", "-t", session, "@agent_pane", pane]);
    }
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
    // If the user is actively watching this pane right now, there is nothing
    // left to "discover" later — go straight to idle instead of done, so the
    // badge does not get stuck showing done for the current session/pane.
    setState(isWatchedAgentPane() ? "idle" : "done");
  });

  pi.on("session_shutdown", async () => {
    setState("idle");
  });
}
