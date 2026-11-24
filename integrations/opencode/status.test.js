import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStatusPlugin } from './index.js';
const tick = () => new Promise(resolve => setImmediate(resolve));
const event = (sessionID, type, seq) => ({ id: `event${seq}`, created: Date.now(), type: `session.execution.${type}`, durable: { seq }, data: { sessionID, text: 'must not be persisted' } });

test('failed terminal write rotates source epoch before another session recovers', async () => {
  const output = [];
  const plugin = createStatusPlugin({ sharedKey: Symbol(),
    writeRecord: (name, record) => { if (record.state === 'completed') throw Error('disk error'); output.push({name, record}); },
    schedule: () => 1, cancel: () => {}, retry: () => new Promise(() => {}),
  });
  const stop = plugin.setup({ event: { subscribe: async function* () {
    yield event('ses_A', 'started', 1); yield event('ses_A', 'succeeded', 2); yield event('ses_B', 'started', 1);
  } } });
  await tick(); stop();
  const a = output.find(x => x.record.sessionID === 'ses_A').record;
  const b = output.find(x => x.record.sessionID === 'ses_B').record;
  assert.notEqual(a.producer, b.producer);
  assert.equal(output.at(-1).record.producer, b.producer);
  assert.ok(output.every(x => !JSON.stringify(x).includes('must not be persisted')));
});

test('stream failure resubscribes with fresh epoch and dispose stops subscription', async () => {
  let attempts = 0; const output = []; let stopped = false;
  const plugin = createStatusPlugin({ sharedKey: Symbol(), writeRecord: (_, r) => output.push(r),
    schedule: () => 1, cancel: () => {}, retry: async () => {},
  });
  const stop = plugin.setup({ event: { subscribe: async function* ({signal}) {
    attempts++;
    if (attempts === 1) { yield event('ses_A', 'started', 1); throw Error('disconnected'); }
    yield event('ses_B', 'started', 1);
    await new Promise(resolve => signal.addEventListener('abort', resolve, {once:true})); stopped = true;
  } } });
  await tick(); stop(); await tick();
  assert.equal(attempts, 2); assert.equal(stopped, true);
  assert.notEqual(output.find(x => x.sessionID === 'ses_A').producer, output.find(x => x.sessionID === 'ses_B').producer);
});
