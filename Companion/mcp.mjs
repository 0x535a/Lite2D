// Per-character stdio MCP entrypoint. The model cannot choose its sender identity.
import { createInterface } from 'node:readline';

const schema = (properties = {}, required = []) => ({ type: 'object', properties, required, additionalProperties: false });
const string = { type: 'string' };
export const tools = [
  { name: 'companion_list_characters', description: 'List visible companions available to talk to.', inputSchema: schema() },
  { name: 'companion_send_message', description: 'Say a short visible message to another character. Queues delivery; never waits for a reply.', inputSchema: schema({ to: string, text: string }, ['to', 'text']) },
  { name: 'observer_list_sessions', description: 'List authorized observed work sessions.', inputSchema: schema() },
  { name: 'observer_get_activity', description: 'Read the cached, filtered recent activity for an authorized session.', inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'observer_get_recent_work', description: 'Read filtered activity across authorized work sessions.', inputSchema: schema() },
  { name: 'observer_get_session_summary', description: 'Read bounded evidence for a session; distinguish facts from your interpretation.', inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'observer_watch_session', description: 'Prioritize an already authorized session; cannot grant access.', inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'observer_unwatch_session', description: 'Stop prioritizing a session.', inputSchema: schema({ sessionRef: string }, ['sessionRef']) },
  { name: 'public_record_list', description: 'List shared memory records.', inputSchema: schema() },
  { name: 'public_record_read', description: 'Read a shared memory Markdown record and its revision.', inputSchema: schema({ path: string }, ['path']) },
  { name: 'public_record_update', description: 'Update shared memory with a source and expected revision; conflict requires rereading.', inputSchema: schema({ path: string, content: string, expectedRevision: string }, ['path', 'content', 'expectedRevision']) },
  { name: 'private_memory_read', description: 'Read your own private long-term notes.', inputSchema: schema() },
  { name: 'private_memory_update', description: 'Update only your own private long-term notes.', inputSchema: schema({ content: string }, ['content']) },
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
