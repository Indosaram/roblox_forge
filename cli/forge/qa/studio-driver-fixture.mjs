import { createInterface } from 'node:readline';
const lines = createInterface({ input: process.stdin });
for await (const line of lines) {
  const message = JSON.parse(line);
  if (message.id === undefined) continue;
  const result = message.method === 'initialize'
    ? { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1' } }
    : message.method === 'tools/list'
      ? { tools: [{ name: 'list_roblox_studios', inputSchema: { type: 'object' } }] }
      : { content: [{ type: 'text', text: JSON.stringify({ studios: [{ id: 'fixture', name: 'protocol only' }] }) }] };
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, result })}\n`);
}
