import { mkdirSync, lstatSync, writeFileSync, renameSync, unlinkSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const root = join(homedir(), 'Library/Application Support/AgentHud/activity');
const states = {
  'session.execution.started': 'running',
  'session.execution.succeeded': 'completed',
  'session.execution.failed': 'failed',
  'session.execution.interrupted': 'interrupted',
};
function write(name, value) {
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const dir = lstatSync(root);
  if (!dir.isDirectory() || dir.isSymbolicLink() || dir.uid !== process.getuid() || (dir.mode & 0o077)) throw Error('Unsafe status directory');
  const temporary = join(root, `.${randomUUID()}.tmp`);
  try {
    writeFileSync(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
    renameSync(temporary, join(root, name));
  } finally { try { unlinkSync(temporary); } catch {} }
}
function wait(milliseconds, signal) {
  return new Promise(resolve => {
    if (signal.aborted) return resolve();
    const finish = () => { clearTimeout(timer); signal.removeEventListener('abort', finish); resolve(); };
    const timer = setTimeout(finish, milliseconds);
    signal.addEventListener('abort', finish, { once: true });
  });
}

// Plain Plugin.define object contract. Dependencies are injected only by synthetic tests.
export function createStatusPlugin({ writeRecord = write, schedule = setInterval, cancel = clearInterval,
  retry = wait, sharedKey = Symbol.for('agenthud.status.bridge.v1') } = {}) {
  function release() {
    const bridge = globalThis[sharedKey];
    if (!bridge || --bridge.refs > 0) return;
    bridge.controller.abort();
    if (bridge.timer != null) cancel(bridge.timer);
    delete globalThis[sharedKey];
  }
  return {
    id: 'agenthud-status',
    setup(ctx) {
      if (globalThis[sharedKey]) { globalThis[sharedKey].refs++; return release; }
      const controller = new AbortController();
      const bridge = { refs: 1, controller, timer: null };
      globalThis[sharedKey] = bridge;
      void (async () => {
        let delay = 1000;
        while (!controller.signal.aborted) {
          // A disconnected stream can miss completion. A new epoch never revives old running records.
          let producer = randomUUID();
          let healthy = true;
          const invalidate = () => { healthy = false; producer = randomUUID(); };
          const heartbeat = () => {
            if (!healthy || controller.signal.aborted) return;
            try { writeRecord(`openCode-heartbeat-${producer}.json`, { version: 1, app: 'openCode', producer, timestamp: Date.now() }); }
            catch { invalidate(); }
          };
          try {
            const events = ctx.event.subscribe({ signal: controller.signal, types: Object.keys(states) });
            heartbeat(); bridge.timer = schedule(heartbeat, 2000);
            for await (const event of events) {
              if (controller.signal.aborted) break;
              const sessionID = event.data?.sessionID;
              const state = states[event.type];
              const sequence = Number(event.durable?.seq);
              if (!state || typeof sessionID !== 'string' || !/^ses_[A-Za-z0-9]{1,100}$/.test(sessionID) || sessionID.includes('\n') ||
                  typeof event.id !== 'string' || !event.id.length || event.id.length > 150 ||
                  !Number.isSafeInteger(sequence) || sequence < 0 || !Number.isFinite(event.created)) { invalidate(); continue; }
              try {
                writeRecord(`openCode-${sessionID}.json`, { version: 1, app: 'openCode', sessionID, state, producer,
                  eventID: event.id, sequence, timestamp: event.created });
                healthy = true; heartbeat(); delay = 1000;
              } catch { invalidate(); }
            }
          } catch {} finally {
            if (bridge.timer != null) cancel(bridge.timer);
            bridge.timer = null;
          }
          if (!controller.signal.aborted) { await retry(delay, controller.signal); delay = Math.min(delay * 2, 30_000); }
        }
      })();
      return release;
    },
  };
}
export default createStatusPlugin();
