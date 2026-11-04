import { mkdir } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { Controller } from './controller.mjs';
import { clean } from './policy.mjs';

const root = process.env.LITE2D_COMPANION_ROOT;
if (!root?.startsWith('/')) throw new Error('Companion root required');
await mkdir(root, { recursive: true, mode: 0o700 });
const send = event => process.stdout.write(JSON.stringify(event) + '\n');
const controller = new Controller({ root, send, opencode: process.env.LITE2D_OPENCODE, codex: process.env.LITE2D_CODEX });
await controller.start();
const input = createInterface({ input: process.stdin });
let chain = Promise.resolve();
input.on('line', line => {
  if (line.length > 1024 * 1024) return;
  try {
    const command = JSON.parse(line);
    if (command.type === 'stop' || command.type === 'configure') controller.command(command).catch(e => send({ type: 'error', message: clean(e.message, 200) }));
    else chain = chain.then(() => controller.command(command)).catch(e => send({ type: 'error', message: clean(e.message, 200) }));
  } catch { send({ type: 'error', message: 'Invalid host message' }); }
});
let closing = false;
async function shutdown() { if (closing) return; closing = true; await controller.close(); process.exit(0); }
input.on('close', shutdown); process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
