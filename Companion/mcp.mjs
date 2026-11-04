// Per-character stdio MCP entrypoint. The model cannot choose its sender identity.
import { createInterface } from 'node:readline';
import { TOOL_DESCRIPTIONS } from './prompt.mjs';

const schema = (properties = {}, required = []) => ({ type: 'object', properties, required, additionalProperties: false });
const string = { type: 'string' };
export const tools = [
  { name: 'companion_list_characters', description: TOOL_DESCRIPTIONS.companion_list_characters, inputSchema: schema() },
  { name: 'companion_send_message', description: TOOL_DESCRIPTIONS.companion_send_message, inputSchema: schema({ to: string, text: string }, ['to', 'text']) },
  { name: 'observer_list_sessions', description: TOOL_DESCRIPTIONS.observer_list_sessions, inputSchema: schema() },
  { name: 'observer_get_activity', description: TOOL_DESCRIPTIONS.observer_get_activity, inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'observer_get_recent_work', description: TOOL_DESCRIPTIONS.observer_get_recent_work, inputSchema: schema() },
  { name: 'observer_get_session_summary', description: TOOL_DESCRIPTIONS.observer_get_session_summary, inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'observer_watch_session', description: TOOL_DESCRIPTIONS.observer_watch_session, inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'observer_unwatch_session', description: TOOL_DESCRIPTIONS.observer_unwatch_session, inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'public_record_list', description: TOOL_DESCRIPTIONS.public_record_list, inputSchema: schema() },
  { name: 'public_record_read', description: TOOL_DESCRIPTIONS.public_record_read, inputSchema: schema({ path: string }, ['path']) },
  { name: 'public_record_update', description: TOOL_DESCRIPTIONS.public_record_update, inputSchema: schema({ path: string, content: string, expectedRevision: string }, ['path', 'content', 'expectedRevision']) },
  { name: 'private_memory_read', description: TOOL_DESCRIPTIONS.private_memory_read, inputSchema: schema() },
  { name: 'private_memory_update', description: TOOL_DESCRIPTIONS.private_memory_update, inputSchema: schema({ content: string }, ['content']) },
];
if (process.argv[1]?.endsWith('/mcp.mjs')) {
  const write = value => process.stdout.write(JSON.stringify(value) + '\n');
  const lines = createInterface({ input: process.stdin });
  lines.on('line', async line => {
    let m;
    try {
      m = JSON.parse(line);
      if (!('id' in m)) return;
      let result;
      if (m.method === 'initialize') result = { protocolVersion: m.params?.protocolVersion ?? '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'lite2d-companion', version: '1.1.0' } };
      else if (m.method === 'ping') result = {};
      else if (m.method === 'tools/list') result = { tools };
      else if (m.method === 'tools/call') {
        if (!tools.some(t => t.name === m.params?.name)) throw new Error('Unknown tool');
        const response = await fetch(process.env.LITE2D_TOOL_ENDPOINT, {
          method: 'POST', headers: { authorization: `Bearer ${process.env.LITE2D_TOOL_TOKEN}`, 'content-type': 'application/json' },
          body: JSON.stringify({ name: m.params.name, arguments: m.params.arguments ?? {} }), signal: AbortSignal.timeout(15000),
        });
        const data = await response.json();
        result = { content: [{ type: 'text', text: JSON.stringify(data) }], isError: !response.ok };
      } else { write({ jsonrpc: '2.0', id: m.id, error: { code: -32601, message: 'Unsupported method' } }); return; }
      write({ jsonrpc: '2.0', id: m.id, result });
    } catch { if (m && 'id' in m) write({ jsonrpc: '2.0', id: m.id, error: { code: -32603, message: 'Companion tool unavailable' } }); }
  });
}
