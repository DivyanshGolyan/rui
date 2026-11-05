// Real Drift transport: stateless MCP behind Node HTTP/1.1.
// POST /release (authenticated) releases all pending slow calls.
import http from 'node:http';
import { McpServer, createMcpHandler } from '@modelcontextprotocol/server';
import * as z from 'zod';

const token = process.argv[2] ?? process.env.MCP_TOKEN;
if (!token) throw new Error('a bearer token is required');
const releases = new Set();
const textResult = text => ({ content: [{ type: 'text', text }] });
const handler = createMcpHandler(() => {
  const server = new McpServer({ name: 'drift-sdk', version: '1.0.0' });
  server.registerTool('echo', {
    description: 'Return text', inputSchema: z.object({ text: z.string() }),
    annotations: { readOnlyHint: true },
  }, async ({ text }) => textResult(text));
  server.registerTool('fail', { description: 'Return an error', inputSchema: z.object({}) },
    async () => ({ ...textResult('fixture failure'), isError: true }));
  server.registerTool('slow', { description: 'Wait for POST /release', inputSchema: z.object({}) },
    async () => {
      await new Promise(resolve => releases.add(resolve));
      return textResult('released');
    });
  server.registerTool('progress', { description: 'Notify before answering', inputSchema: z.object({}) },
    async (_, ctx) => {
      await ctx.mcpReq.notify({ method: 'notifications/progress', params: {
        progressToken: ctx.mcpReq._meta?.progressToken ?? 'fixture-progress', progress: 1,
      } });
      return textResult('done');
    });
  return server;
}, { legacy: 'stateless' });

http.createServer(async (req, res) => {
  try {
    if (req.headers.authorization !== `Bearer ${token}`) {
      res.writeHead(401).end();
      return;
    }
    if (req.method === 'POST' && req.url === '/release') {
      for (const release of releases) release();
      releases.clear();
      res.writeHead(204).end();
      return;
    }
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const request = new Request(`http://127.0.0.1${req.url}`, {
      method: req.method, headers: req.headers,
      body: req.method === 'POST' ? Buffer.concat(chunks) : undefined,
    });
    const response = await handler.fetch(request);
    res.writeHead(response.status, Object.fromEntries(response.headers));
    if (response.body) for await (const chunk of response.body) res.write(chunk);
    res.end();
  } catch (error) {
    console.error(error);
    res.destroy(error);
  }
}).listen(0, '127.0.0.1', function () {
  console.log(this.address().port);
});
