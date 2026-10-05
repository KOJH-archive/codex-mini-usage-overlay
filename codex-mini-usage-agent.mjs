import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

const args = parseArgs(process.argv.slice(2));
const outPath = resolve(args.out || "codex-mini-usage-status.json");
const intervalMs = Math.max(15_000, Number(args.intervalMs || 60_000));
const codexPath =
  args.codexPath ||
  process.env.CODEX_CLI_PATH ||
  "C:\\Users\\jongh\\AppData\\Local\\OpenAI\\Codex\\bin\\f544b3844e0f14e9\\codex.exe";

mkdirSync(dirname(outPath), { recursive: true });

let lastGood = null;
let child = null;
let nextId = 1;
let buffer = "";
let stopped = false;
const pending = new Map();

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

await poll();
if (args.once) {
  shutdown();
} else {
  setInterval(poll, intervalMs);
}

function parseArgs(argv) {
  const parsed = {};
  for (let i = 0; i < argv.length; i += 1) {
    const current = argv[i];
    if (!current.startsWith("--")) continue;
    const key = current.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) parsed[key] = true;
    else {
      parsed[key] = next;
      i += 1;
    }
  }
  return parsed;
}

async function poll() {
  try {
    await ensureServer();
    const raw = await request("account/rateLimits/read", {
      excludeResetCreditDetails: true,
      supportsLunaReserve: true,
    });
    const normalized = normalize(raw);
    lastGood = normalized;
    writeStatus({ ok: true, ...normalized });
  } catch (error) {
    writeStatus({
      ok: false,
      display: lastGood?.display || "Usage unavailable",
      severity: "unknown",
      updatedAt: new Date().toISOString(),
      error: String(error?.message || error),
      lastGood,
    });
    restartServer();
  }
}

async function ensureServer() {
  if (child && !child.killed) return;

  child = spawn(codexPath, ["app-server", "--stdio"], {
    env: {
      ...process.env,
      HOME: process.env.HOME || "C:\\Users\\jongh",
      USERPROFILE: process.env.USERPROFILE || "C:\\Users\\jongh",
      CODEX_HOME: process.env.CODEX_HOME || "C:\\Users\\jongh\\.codex",
    },
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });

  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString();
    parseMessages();
  });

  child.stderr.on("data", (chunk) => {
    const text = chunk.toString();
    if (!text.includes("PATH aliases")) process.stderr.write(text);
  });

  child.on("exit", (code, signal) => {
    const message = `codex app-server exited (${code ?? signal})`;
    child = null;
    for (const { reject } of pending.values()) reject(new Error(message));
    pending.clear();
  });

  await request("initialize", {
    clientInfo: {
      name: "codex-mini-usage",
      title: "Codex Mini Usage",
      version: "0.1.0",
    },
    capabilities: {
      experimentalApi: true,
      optOutNotificationMethods: [
        "thread/started",
        "thread/statusChanged",
        "thread/tokenUsage/updated",
      ],
    },
  });
}

function restartServer() {
  if (!child) return;
  child.kill();
  child = null;
  buffer = "";
}

function request(method, params = null) {
  const id = nextId++;
  const message = JSON.stringify({ jsonrpc: "2.0", id, method, params });
  child.stdin.write(`${message}\n`);

  return new Promise((resolveRequest, rejectRequest) => {
    const timeout = setTimeout(() => {
      if (pending.delete(id)) {
        rejectRequest(new Error(`Timed out waiting for ${method}`));
      }
    }, 15_000);

    pending.set(id, {
      resolve: (value) => {
        clearTimeout(timeout);
        resolveRequest(value);
      },
      reject: (error) => {
        clearTimeout(timeout);
        rejectRequest(error);
      },
    });
  });
}

function parseMessages() {
  while (true) {
    const newline = buffer.indexOf("\n");
    if (newline === -1) return;

    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (!line) continue;

    let payload;
    try {
      payload = JSON.parse(line);
    } catch {
      continue;
    }

    if (payload.id == null || !pending.has(payload.id)) continue;
    const { resolve, reject } = pending.get(payload.id);
    pending.delete(payload.id);
    if (payload.error) reject(new Error(JSON.stringify(payload.error)));
    else resolve(payload.result);
  }
}

function normalize(raw) {
  const snapshot = raw?.rateLimitsByLimitId?.codex || raw?.rateLimits || {};
  const primary = snapshot.primary || {};
  const secondary = snapshot.secondary || {};
  const fiveHourRemaining = clampPercent(100 - Number(primary.usedPercent ?? 100));
  const weeklyRemaining = clampPercent(100 - Number(secondary.usedPercent ?? 100));
  const fiveHourReset = formatDurationUntil(primary.resetsAt);
  const weeklyReset = formatDurationUntil(secondary.resetsAt);
  const severity = severityFor(Math.min(fiveHourRemaining, weeklyRemaining));
  const display = `5h ${fiveHourRemaining}% (${fiveHourReset}) · W ${weeklyRemaining}% (${weeklyReset})`;

  return {
    display,
    severity,
    updatedAt: new Date().toISOString(),
    accountId: raw?.accountId || null,
    ordinaryUsageAllowed: raw?.ordinaryUsageAllowed ?? null,
    rateLimitReachedType: snapshot.rateLimitReachedType || null,
    resetCreditsAvailable: raw?.rateLimitResetCredits?.availableCount ?? null,
    fiveHour: {
      remainingPercent: fiveHourRemaining,
      usedPercent: Number(primary.usedPercent ?? 0),
      resetsAt: primary.resetsAt ?? null,
      resetIn: fiveHourReset,
      windowDurationMins: primary.windowDurationMins ?? null,
    },
    weekly: {
      remainingPercent: weeklyRemaining,
      usedPercent: Number(secondary.usedPercent ?? 0),
      resetsAt: secondary.resetsAt ?? null,
      resetIn: weeklyReset,
      windowDurationMins: secondary.windowDurationMins ?? null,
    },
  };
}

function clampPercent(value) {
  if (!Number.isFinite(value)) return 0;
  return Math.max(0, Math.min(100, Math.round(value)));
}

function severityFor(remaining) {
  if (remaining < 20) return "critical";
  if (remaining < 50) return "warning";
  return "normal";
}

function formatDurationUntil(epochSeconds) {
  if (!epochSeconds) return "--";
  const seconds = Math.max(0, Math.ceil(epochSeconds - Date.now() / 1000));
  const days = Math.floor(seconds / 86_400);
  const hours = Math.floor((seconds % 86_400) / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);

  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function writeStatus(status) {
  writeFileSync(outPath, `${JSON.stringify(status, null, 2)}\n`, "utf8");
}

function shutdown() {
  if (stopped) return;
  stopped = true;
  if (child) child.kill();
  process.exit(0);
}
