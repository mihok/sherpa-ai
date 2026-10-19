// A 2026-07-28 MCP test server for sherpa_mcp's conformance tests, built on
// the official TypeScript SDK v2 (@modelcontextprotocol/server@2.3.1).
//
//   PORT=<port> LEGACY=reject|stateless node server.mjs
//
// LEGACY=reject (default) makes it a strict modern-only endpoint; LEGACY=
// stateless serves 2025-era traffic too (the SDK's stateless fallback).
// GET /control/tools-changed and /control/resource-updated publish change
// events to open subscriptions/listen streams.
import http from 'node:http';
import {
  acceptedContent,
  completable,
  createMcpHandler,
  fromJsonSchema,
  inputRequired,
  inputResponse,
  McpServer,
} from '@modelcontextprotocol/server';
import * as z from 'zod';

const port = Number(process.env.PORT ?? 0);
const legacy = process.env.LEGACY ?? 'reject';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function factory() {
  const server = new McpServer(
    { name: 'sherpa-modern-test', version: '1.0.0' },
    {
      capabilities: { logging: {}, completions: {}, tools: { listChanged: true }, resources: { subscribe: true, listChanged: true } },
      instructions: 'Modern conformance server.',
    },
  );

  server.registerTool(
    'echo',
    { description: 'Echoes the message', inputSchema: z.object({ message: z.string() }), annotations: { readOnlyHint: true } },
    async ({ message }) => ({ content: [{ type: 'text', text: `Echo: ${message}` }] }),
  );

  server.registerTool(
    'weather',
    {
      description: 'Weather for a region (mirrors region into Mcp-Param-Region)',
      inputSchema: fromJsonSchema({
        type: 'object',
        properties: { region: { type: 'string', 'x-mcp-header': 'Region' } },
        required: ['region'],
      }),
    },
    async ({ region }) => ({
      content: [{ type: 'text', text: `Sunny in ${region}` }],
      structuredContent: { region, temp: 21 },
    }),
  );

  server.registerTool(
    'confirm',
    { description: 'Asks for confirmation via MRTR elicitation', inputSchema: z.object({ action: z.string() }) },
    async ({ action }, ctx) => {
      const schema = z.object({ confirm: z.boolean() });
      const view = inputResponse(ctx.mcpReq.inputResponses, 'confirm');
      if (view.kind === 'elicit' && view.action !== 'accept') {
        return { content: [{ type: 'text', text: `${view.action} ${action}` }] };
      }
      const confirmed = acceptedContent(ctx.mcpReq.inputResponses, 'confirm', schema);
      if (confirmed?.confirm !== true) {
        return inputRequired({
          inputRequests: { confirm: inputRequired.elicit({ message: `Really ${action}?`, requestedSchema: schema }) },
          requestState: 'round-1',
        });
      }
      return { content: [{ type: 'text', text: `confirmed ${action} (state ${ctx.mcpReq.requestState()})` }] };
    },
  );

  server.registerTool(
    'ask-model',
    { description: 'Asks the client LLM via MRTR sampling', inputSchema: z.object({ question: z.string() }) },
    async ({ question }, ctx) => {
      const view = inputResponse(ctx.mcpReq.inputResponses, 'answer');
      if (view.kind === 'sampling') {
        const c = view.result.content;
        const text = Array.isArray(c) ? c.map((b) => b.text).join('') : c.text;
        return { content: [{ type: 'text', text: `model ${view.result.model} said: ${text}` }] };
      }
      return inputRequired({
        inputRequests: {
          answer: inputRequired.createMessage({
            messages: [{ role: 'user', content: { type: 'text', text: question } }],
            maxTokens: 64,
          }),
        },
      });
    },
  );

  server.registerTool(
    'progress',
    { description: 'Reports progress and logs', inputSchema: z.object({ steps: z.number() }) },
    async ({ steps }, ctx) => {
      const token = ctx.mcpReq._meta?.progressToken;
      for (let i = 1; i <= steps; i++) {
        await sleep(30);
        if (token !== undefined) {
          await ctx.mcpReq.notify({ method: 'notifications/progress', params: { progressToken: token, progress: i, total: steps } });
        }
      }
      await ctx.mcpReq.log('info', `finished ${steps} steps`);
      return { content: [{ type: 'text', text: `did ${steps} steps` }] };
    },
  );

  server.registerTool(
    'slow',
    { description: 'Waits until cancelled', inputSchema: z.object({}) },
    async (_args, ctx) => {
      await new Promise((resolve) => {
        const t = setTimeout(resolve, 30000);
        ctx.mcpReq.signal.addEventListener('abort', () => {
          clearTimeout(t);
          cancelled++;
          resolve();
        });
      });
      return { content: [{ type: 'text', text: 'too late' }] };
    },
  );

  server.registerResource(
    'config',
    'file:///config.json',
    { mimeType: 'application/json', description: 'App config' },
    async (uri) => ({ contents: [{ uri: uri.href, mimeType: 'application/json', text: '{"v":1}' }] }),
  );

  server.registerPrompt(
    'greet',
    {
      description: 'Greets someone',
      argsSchema: z.object({ who: completable(z.string(), (v) => ['alice', 'bob', 'carol'].filter((n) => n.startsWith(v))) }),
    },
    ({ who }) => ({ messages: [{ role: 'user', content: { type: 'text', text: `Hello ${who}` } }] }),
  );
  return server;
}

let cancelled = 0;
const handler = createMcpHandler(factory, { legacy, onerror: (e) => console.error('[mcp]', e.message) });

http
  .createServer(async (req, res) => {
    if (req.url === '/control/tools-changed') return res.end(String(handler.notify.toolsChanged() ?? 'ok'));
    if (req.url === '/control/resource-updated') return res.end(String(handler.notify.resourceUpdated('file:///config.json') ?? 'ok'));
    if (req.url === '/control/cancelled') return res.end(String(cancelled));
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const ac = new AbortController();
    res.on('close', () => ac.abort());
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) if (typeof v === 'string') headers.set(k, v);
    const request = new Request(`http://${req.headers.host}${req.url}`, {
      method: req.method,
      headers,
      body: req.method === 'GET' || req.method === 'HEAD' || req.method === 'DELETE' ? undefined : Buffer.concat(chunks),
      signal: ac.signal,
    });
    let response;
    try {
      response = await handler.fetch(request);
    } catch (e) {
      res.writeHead(500).end(String(e));
      return;
    }
    res.writeHead(response.status, Object.fromEntries(response.headers));
    if (!response.body) return res.end();
    const reader = response.body.getReader();
    ac.signal.addEventListener('abort', () => reader.cancel().catch(() => {}));
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(value);
      }
    } catch {
      // client went away
    }
    res.end();
  })
  .listen(port, '127.0.0.1', function () {
    console.log(`listening ${this.address().port}`);
  });
