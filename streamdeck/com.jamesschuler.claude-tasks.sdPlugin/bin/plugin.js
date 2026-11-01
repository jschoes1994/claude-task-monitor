#!/usr/bin/env node
// Claude Tasks for Stream Deck.
// Each key shows one Claude Code / Cowork session: blue = working, orange = needs
// input, green = done. Press to open the session in Claude Desktop.
//
// The scanner is a port of the Claude Task Monitor macOS app and reads:
//   transcripts      ~/.claude/projects/<proj>/<sessionId>.jsonl
//   hook status      ~/.claude/task-monitor/<sessionId>.json (+ .agents/ markers)
//   desktop titles   <Claude app data>/claude-code-sessions/**/local_*.json
//   cowork sandboxes <Claude app data>/local-agent-mode-sessions/**
//
// Standalone test (no Stream Deck needed):  node bin/plugin.js --scan-test

"use strict";

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFile } = require("child_process");

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

const HOME = os.homedir();
const CLAUDE_DIR = path.join(HOME, ".claude");
const PROJECTS = path.join(CLAUDE_DIR, "projects");
const TASK_MONITOR = path.join(CLAUDE_DIR, "task-monitor");
const APP_SUPPORT =
  process.platform === "darwin"
    ? path.join(HOME, "Library", "Application Support", "Claude")
    : path.join(process.env.APPDATA || "", "Claude");
const DESKTOP_SESSIONS = path.join(APP_SUPPORT, "claude-code-sessions");
const COWORK_SESSIONS = path.join(APP_SUPPORT, "local-agent-mode-sessions");

const MAX_AGE_MS = 8 * 3600 * 1000;
const WORKING_WINDOW_S = 30;

// ---------------------------------------------------------------------------
// Small fs helpers (everything tolerates missing files)
// ---------------------------------------------------------------------------

const safeDirs = (p) => {
  try {
    return fs
      .readdirSync(p, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => path.join(p, d.name));
  } catch {
    return [];
  }
};
const safeFiles = (p, suffix) => {
  try {
    return fs
      .readdirSync(p)
      .filter((f) => f.endsWith(suffix))
      .map((f) => path.join(p, f));
  } catch {
    return [];
  }
};
const readJSON = (p) => {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};
const mtimeOf = (p) => {
  try {
    return fs.statSync(p).mtimeMs;
  } catch {
    return 0;
  }
};

// ---------------------------------------------------------------------------
// Transcript parsing
// ---------------------------------------------------------------------------

function readTail(file, bytes) {
  try {
    const fd = fs.openSync(file, "r");
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, bytes);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    fs.closeSync(fd);
    return buf.toString("utf8");
  } catch {
    return "";
  }
}

// Newest non-sidechain user/assistant message in the transcript.
function lastEntry(file) {
  const lines = readTail(file, 128 * 1024).split("\n");
  let lastAssistantText = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    let obj;
    try {
      obj = JSON.parse(lines[i]);
    } catch {
      continue;
    }
    if (obj.isSidechain === true) continue;
    const msg = obj.message;
    const role = msg && msg.role;
    if (role !== "user" && role !== "assistant") {
      continue;
    }
    if (lastAssistantText === null && role === "assistant" && Array.isArray(msg.content)) {
      for (const c of msg.content) {
        if (c && c.type === "text" && c.text) lastAssistantText = c.text;
      }
      // keep scanning only if we haven't found the terminal entry yet
    }
    const entry = {
      role,
      endsWithToolUse: false,
      interrupted: false,
      timestamp: obj.timestamp ? Date.parse(obj.timestamp) : null,
      lastAssistantText,
    };
    if (Array.isArray(msg.content)) {
      const last = msg.content[msg.content.length - 1];
      entry.endsWithToolUse = !!last && last.type === "tool_use";
      if (role === "user") {
        entry.interrupted = msg.content.some(
          (c) => c && typeof c.text === "string" && c.text.includes("[Request interrupted")
        );
      }
    } else if (typeof msg.content === "string" && role === "user") {
      entry.interrupted = msg.content.includes("[Request interrupted");
    }
    // If the newest entry is a user turn, look back for the newest assistant text.
    if (entry.lastAssistantText === null) {
      for (let j = i - 1; j >= 0; j--) {
        let o2;
        try {
          o2 = JSON.parse(lines[j]);
        } catch {
          continue;
        }
        if (o2.isSidechain === true) continue;
        const m2 = o2.message;
        if (!m2 || m2.role !== "assistant" || !Array.isArray(m2.content)) continue;
        for (const c of m2.content) {
          if (c && c.type === "text" && c.text) entry.lastAssistantText = c.text;
        }
        if (entry.lastAssistantText) break;
      }
    }
    return entry;
  }
  return null;
}

const firstPromptCache = new Map();

function firstUserMessage(file) {
  if (firstPromptCache.has(file)) return firstPromptCache.get(file);
  let result = "Session " + path.basename(file, ".jsonl").slice(0, 8);
  try {
    const head = fs.readFileSync(file, { encoding: "utf8", flag: "r" }).slice(0, 256 * 1024);
    for (const line of head.split("\n").slice(0, 200)) {
      let obj;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      if (obj.isSidechain === true) continue;
      const msg = obj.message;
      if (!msg || msg.role !== "user") continue;
      let text = null;
      if (typeof msg.content === "string") text = msg.content;
      else if (Array.isArray(msg.content)) {
        const t = msg.content.find((c) => c && typeof c.text === "string" && c.text);
        text = t ? t.text : null;
      }
      if (!text || !text.trim()) continue;
      if (text.startsWith("<") || text.startsWith("Caveat:")) continue;
      result = squeeze(text, 60);
      break;
    }
  } catch {}
  firstPromptCache.set(file, result);
  return result;
}

function squeeze(s, max) {
  s = s.replace(/\s+/g, " ").trim();
  return s.length <= max ? s : s.slice(0, max) + "…";
}

// ---------------------------------------------------------------------------
// Status resolution (hooks first, transcript heuristics as fallback)
// ---------------------------------------------------------------------------

function resolveStatus(sessionId, entry, activityMs, nowMs) {
  if (entry.interrupted) return "done";
  const ageS = (nowMs - activityMs) / 1000;

  const hook = readJSON(path.join(TASK_MONITOR, sessionId + ".json"));
  if (hook && typeof hook.ts === "number" && hook.ts >= activityMs / 1000 - 5) {
    if (hook.state === "needs_input") return "needs_input";
    if (hook.state === "working") return "working";
    if (hook.state === "done") return "done";
  }

  if (ageS < WORKING_WINDOW_S) return "working";
  if (entry.role === "assistant" && entry.endsWithToolUse) return "needs_input";
  if (entry.role === "user" && ageS < 90) return "working";
  return "done";
}

function runningAgentCount(sessionId, nowMs) {
  const dir = path.join(TASK_MONITOR, sessionId + ".agents");
  try {
    return fs
      .readdirSync(dir)
      .filter((f) => nowMs - mtimeOf(path.join(dir, f)) < 4 * 3600 * 1000).length;
  } catch {
    return 0;
  }
}

// ---------------------------------------------------------------------------
// Desktop metadata (tab titles + ids for deep links)
// ---------------------------------------------------------------------------

function loadDesktopSessions() {
  const best = new Map(); // cliSessionId -> {desktopId, title, activity}
  if (!fs.existsSync(DESKTOP_SESSIONS)) return best;
  for (const org of safeDirs(DESKTOP_SESSIONS))
    for (const ws of safeDirs(org))
      for (const file of safeFiles(ws, ".json")) {
        const obj = readJSON(file);
        if (!obj || !obj.cliSessionId || !obj.sessionId || obj.isArchived === true) continue;
        const title = obj.title && obj.title.length ? obj.title : null;
        const activity = obj.lastActivityAt || 0;
        const prev = best.get(obj.cliSessionId);
        if (prev) {
          const prevRank = [prev.title ? 1 : 0, prev.activity];
          const curRank = [title ? 1 : 0, activity];
          if (
            curRank[0] < prevRank[0] ||
            (curRank[0] === prevRank[0] && curRank[1] <= prevRank[1])
          )
            continue;
        }
        best.set(obj.cliSessionId, { desktopId: obj.sessionId, title, activity });
      }
  return best;
}

// ---------------------------------------------------------------------------
// Scan
// ---------------------------------------------------------------------------

function scan() {
  const now = Date.now();
  const found = [];
  const desktop = loadDesktopSessions();

  for (const projDir of safeDirs(PROJECTS))
    for (const file of safeFiles(projDir, ".jsonl")) {
      const sessionId = path.basename(file, ".jsonl");
      if (sessionId.startsWith("agent-")) continue;
      if (now - mtimeOf(file) > MAX_AGE_MS) continue;
      const info = inspect(file, now, desktop.get(sessionId), "code", null);
      if (info) found.push(info);
    }

  // Cowork sandboxes
  for (const org of safeDirs(COWORK_SESSIONS))
    for (const ws of safeDirs(org))
      for (const meta of safeFiles(ws, ".json")) {
        if (!path.basename(meta).startsWith("local_")) continue;
        const obj = readJSON(meta);
        if (!obj || obj.isArchived === true || !obj.sessionId || !obj.cliSessionId) continue;
        if (now - (obj.lastActivityAt || 0) > MAX_AGE_MS) continue;
        const transcript = coworkTranscript(path.join(ws, obj.sessionId), obj.cliSessionId);
        if (!transcript || now - mtimeOf(transcript) > MAX_AGE_MS) continue;
        const info = inspect(
          transcript,
          now,
          { desktopId: obj.sessionId, title: obj.title || "Cowork session" },
          "cowork",
          obj.title || "Cowork session"
        );
        if (info) found.push(info);
      }

  const order = { needs_input: 0, working: 1, done: 2 };
  found.sort(
    (a, b) => order[a.status] - order[b.status] || b.lastActivity - a.lastActivity
  );
  return found.slice(0, 30);
}

function coworkTranscript(sandbox, cliId) {
  for (const dir of safeDirs(path.join(sandbox, ".claude", "projects"))) {
    const candidate = path.join(dir, cliId + ".jsonl");
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function inspect(file, now, desktopInfo, kind, forcedName) {
  const entry = lastEntry(file);
  if (!entry) return null;
  const sessionId = path.basename(file, ".jsonl");
  const activity = entry.timestamp || mtimeOf(file);
  let status = resolveStatus(sessionId, entry, activity, now);
  const agents = runningAgentCount(sessionId, now);
  if (agents > 0 && status === "done") status = "working";
  const name =
    forcedName || (desktopInfo && desktopInfo.title) || firstUserMessage(file);
  return {
    sessionId,
    kind,
    name,
    status,
    agents,
    lastActivity: activity,
    desktopId: desktopInfo ? desktopInfo.desktopId : null,
  };
}

// ---------------------------------------------------------------------------
// Standalone test mode
// ---------------------------------------------------------------------------

if (process.argv.includes("--scan-test")) {
  const sessions = scan();
  for (const s of sessions)
    console.log(
      `${s.status.padEnd(11)} ${s.kind.padEnd(6)} agents:${s.agents} ` +
        `${new Date(s.lastActivity).toLocaleTimeString()} ${s.name}`
    );
  if (!sessions.length) console.log("(no sessions active in the last 8 hours)");
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Key rendering
// ---------------------------------------------------------------------------

const COLORS = {
  working: "#1E66D0",
  needs_input: "#E08A00",
  done: "#1F9D55",
  gone: "#3A3A3E",
};
const LABELS = {
  working: "Working",
  needs_input: "Needs input",
  done: "Done",
  gone: "Not found",
};

function esc(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function wrap(text, perLine, maxLines) {
  const words = text.split(" ");
  const lines = [];
  let cur = "";
  for (const w of words) {
    if ((cur + " " + w).trim().length > perLine && cur) {
      lines.push(cur);
      cur = w;
      if (lines.length === maxLines) break;
    } else {
      cur = (cur + " " + w).trim();
    }
  }
  if (lines.length < maxLines && cur) lines.push(cur);
  if (lines.length === maxLines && words.join(" ").length > lines.join(" ").length)
    lines[maxLines - 1] = lines[maxLines - 1].slice(0, perLine - 1) + "…";
  return lines;
}

function keyImage(session) {
  const status = session ? session.status : "gone";
  const color = COLORS[status];
  const name = session ? session.name : "No session";
  let label = LABELS[status];
  if (session && session.agents > 0)
    label += ` · ${session.agents} agent${session.agents === 1 ? "" : "s"}`;
  const lines = wrap(name, 13, 3);
  const text = lines
    .map(
      (l, i) =>
        `<text x="72" y="${46 + i * 22}" font-size="18" font-weight="600" fill="#FFFFFF" text-anchor="middle" font-family="-apple-system, Segoe UI, sans-serif">${esc(l)}</text>`
    )
    .join("");
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144">` +
    `<rect width="144" height="144" rx="16" fill="#1C1C1E"/>` +
    `<rect width="144" height="10" rx="5" y="0" fill="${color}"/>` +
    `<circle cx="16" cy="126" r="7" fill="${color}"/>` +
    text +
    `<text x="30" y="131" font-size="14" fill="${color}" font-family="-apple-system, Segoe UI, sans-serif">${esc(label)}</text>` +
    `</svg>`;
  return "data:image/svg+xml;base64," + Buffer.from(svg).toString("base64");
}

// ---------------------------------------------------------------------------
// Key preview mode: render current sessions as an HTML page of key images.
// Usage: node bin/plugin.js --key-preview <out.html>
// ---------------------------------------------------------------------------

if (process.argv.includes("--key-preview")) {
  const out = process.argv[process.argv.indexOf("--key-preview") + 1] || "key-preview.html";
  const sessions = scan();
  const cells = sessions
    .concat([null]) // the gray "no session" key
    .map(
      (s) =>
        `<div class="cell"><img src="${keyImage(s)}" width="144" height="144">` +
        `<div class="cap">${s ? s.name.replace(/</g, "&lt;") : "(unbound / inactive)"}</div></div>`
    )
    .join("\n");
  fs.writeFileSync(
    out,
    `<!DOCTYPE html><html><head><meta charset="utf-8"><style>
    body{background:#111;font-family:-apple-system,sans-serif;padding:24px}
    .grid{display:flex;flex-wrap:wrap;gap:18px}
    .cell{text-align:center}
    img{border-radius:14px;box-shadow:0 4px 14px rgba(0,0,0,.6)}
    .cap{color:#888;font-size:11px;margin-top:6px;max-width:144px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    </style></head><body><div class="grid">${cells}</div></body></html>`
  );
  console.log("wrote " + out);
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Stream Deck protocol
// ---------------------------------------------------------------------------

const argv = {};
for (let i = 2; i < process.argv.length; i += 2) argv[process.argv[i]] = process.argv[i + 1];

const WebSocket = require("ws");
const ws = new WebSocket("ws://127.0.0.1:" + argv["-port"]);
const keys = new Map(); // context -> settings {mode, sessionId, autoIndex}
let latest = [];

function send(obj) {
  try {
    ws.send(JSON.stringify(obj));
  } catch {}
}

ws.on("open", () => {
  send({ event: argv["-registerEvent"], uuid: argv["-pluginUUID"] });
});

ws.on("message", (data) => {
  let e;
  try {
    e = JSON.parse(data);
  } catch {
    return;
  }
  switch (e.event) {
    case "willAppear":
      keys.set(e.context, (e.payload && e.payload.settings) || {});
      refresh();
      break;
    case "didReceiveSettings":
      keys.set(e.context, (e.payload && e.payload.settings) || {});
      renderKey(e.context);
      break;
    case "willDisappear":
      keys.delete(e.context);
      break;
    case "keyDown":
      press(e.context);
      break;
    case "propertyInspectorDidAppear":
      sendSessionList(e.context);
      break;
    case "sendToPlugin":
      if (e.payload && e.payload.event === "getSessions") sendSessionList(e.context);
      break;
  }
});

function resolve(settings) {
  if (settings && settings.mode === "session" && settings.sessionId)
    return latest.find((s) => s.sessionId === settings.sessionId) || null;
  const idx = (settings && settings.autoIndex) || 0;
  return latest[idx] || null;
}

function renderKey(context) {
  const session = resolve(keys.get(context));
  send({
    event: "setImage",
    context,
    payload: { image: keyImage(session), target: 0 },
  });
  send({ event: "setTitle", context, payload: { title: "", target: 0 } });
}

function refresh() {
  try {
    latest = scan();
  } catch {
    return;
  }
  for (const context of keys.keys()) renderKey(context);
}

function press(context) {
  const session = resolve(keys.get(context));
  if (!session) return;
  if (session.desktopId) {
    const route = session.kind === "cowork" ? "local_sessions" : "claude-code-desktop";
    openURL(`claude://claude.ai/${route}/${session.desktopId}`);
  } else if (process.platform === "darwin") {
    execFile("open", ["-a", "Claude"], () => {});
  }
  send({ event: "showOk", context });
}

function openURL(url) {
  if (process.platform === "darwin") execFile("open", [url], () => {});
  else execFile("cmd", ["/c", "start", "", url], () => {});
}

function sendSessionList(context) {
  send({
    event: "sendToPropertyInspector",
    action: "com.jamesschuler.claude-tasks.session",
    context,
    payload: {
      event: "sessions",
      sessions: latest.map((s) => ({
        sessionId: s.sessionId,
        name: s.name,
        status: s.status,
        kind: s.kind,
      })),
    },
  });
}

setInterval(refresh, 2000);
refresh();
