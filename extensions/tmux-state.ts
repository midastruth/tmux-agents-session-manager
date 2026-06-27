import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";

const VALID_STATES = new Set(["blocked", "working", "done", "idle"]);
let tmuxSession: string | undefined;

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

  // Session-scoped state: keeps managed sessions (one agent per session)
  // working as before.
  const session = currentTmuxSession();
  if (session) {
    addTmuxCommand(["set-option", "-t", session, "@agent_state", state]);
    addTmuxCommand(["set-option", "-t", session, "@agent_state_at", now]);
  }

  if (args.length > 0) runTmux(args);
}

export default function piTmuxStateExtension(pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    setState("idle");
  });

  pi.on("agent_start", async () => {
    setState("working");
  });

  pi.on("agent_end", async () => {
    setState("done");
  });

  pi.on("session_shutdown", async () => {
    setState("idle");
  });
}
