// A small Model Context Protocol server core: JSON-RPC 2.0 over the
// Streamable HTTP transport, stateless (each POST carries a message or a
// batch and gets JSON back; no sessions, no server-to-client stream). That is
// what remote MCP clients use today: Claude (claude.ai connectors, Claude
// Desktop, Claude Code, the Messages API MCP connector) and ChatGPT
// (connectors / developer mode, the Responses API `mcp` tool).
//
// Only tools are served (no resources or prompts), all read-only. No Deno or
// Node APIs, so vitest imports it too. Spec: modelcontextprotocol.io.

export const SUPPORTED_PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05'] as const;
export const LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0];

export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };

export interface JsonRpcRequest {
  jsonrpc: '2.0';
  id?: string | number | null;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

/** JSON Schema for a tool's arguments (object at the top). */
export interface ToolInputSchema {
  type: 'object';
  properties: Record<string, unknown>;
  required?: string[];
  additionalProperties?: boolean;
}

export interface ToolAnnotations {
  title?: string;
  readOnlyHint?: boolean;
  destructiveHint?: boolean;
  idempotentHint?: boolean;
  openWorldHint?: boolean;
}

export interface ToolContext {
  /** The organizer's org when the request carried a valid API key, else null. */
  orgId: string | null;
}

export interface ToolDefinition {
  name: string;
  title?: string;
  description: string;
  inputSchema: ToolInputSchema;
  annotations?: ToolAnnotations;
  /** Needs an organizer API key (hidden from tools/list without one). */
  requiresOrg?: boolean;
  handler: (args: Record<string, unknown>, ctx: ToolContext) => Promise<unknown>;
}

/** A tool refusing bad input or an unavailable action: shown to the model as an error result, not a protocol error. */
export class ToolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ToolError';
  }
}

export interface McpServer {
  name: string;
  version: string;
  instructions?: string;
  tools: ToolDefinition[];
}

export const ERR = {
  parse: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internal: -32603,
} as const;

function error(id: JsonRpcResponse['id'], code: number, message: string): JsonRpcResponse {
  return { jsonrpc: '2.0', id, error: { code, message } };
}

function isRequest(m: unknown): m is JsonRpcRequest {
  return !!m && typeof m === 'object' && (m as JsonRpcRequest).jsonrpc === '2.0' && typeof (m as JsonRpcRequest).method === 'string';
}

function visibleTools(server: McpServer, ctx: ToolContext): ToolDefinition[] {
  return server.tools.filter((t) => !t.requiresOrg || ctx.orgId);
}

/**
 * One JSON-RPC message. Returns null for notifications (no id), which get no
 * response. `onError` sees unexpected handler failures (log them); the client
 * only gets a generic message.
 */
export async function handleMessage(
  server: McpServer,
  msg: unknown,
  ctx: ToolContext,
  onError: (e: unknown) => void = () => {},
): Promise<JsonRpcResponse | null> {
  if (!isRequest(msg)) {
    const id = (msg as { id?: JsonRpcResponse['id'] } | null)?.id ?? null;
    return error(id, ERR.invalidRequest, 'invalid JSON-RPC request');
  }
  const isNotification = msg.id === undefined;
  const id = msg.id ?? null;
  if (isNotification) return null; // notifications/initialized, cancelled, ...
  const params = (msg.params ?? {}) as Record<string, unknown>;

  switch (msg.method) {
    case 'initialize': {
      const asked = String(params.protocolVersion ?? '');
      const protocolVersion = (SUPPORTED_PROTOCOL_VERSIONS as readonly string[]).includes(asked) ? asked : LATEST_PROTOCOL_VERSION;
      return {
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: server.name, version: server.version },
          ...(server.instructions ? { instructions: server.instructions } : {}),
        },
      };
    }
    case 'ping':
      return { jsonrpc: '2.0', id, result: {} };
    case 'tools/list':
      return {
        jsonrpc: '2.0',
        id,
        result: {
          tools: visibleTools(server, ctx).map((t) => ({
            name: t.name,
            ...(t.title ? { title: t.title } : {}),
            description: t.description,
            inputSchema: t.inputSchema,
            ...(t.annotations ? { annotations: t.annotations } : {}),
          })),
        },
      };
    case 'tools/call': {
      const name = String(params.name ?? '');
      const tool = server.tools.find((t) => t.name === name);
      if (!tool) return error(id, ERR.invalidParams, `unknown tool: ${name}`);
      if (tool.requiresOrg && !ctx.orgId) {
        return { jsonrpc: '2.0', id, result: toolResult({ error: 'this tool needs an Exos organizer API key' }, true) };
      }
      const args = params.arguments;
      if (args !== undefined && (typeof args !== 'object' || args === null || Array.isArray(args))) {
        return error(id, ERR.invalidParams, 'arguments must be an object');
      }
      try {
        const out = await tool.handler((args ?? {}) as Record<string, unknown>, ctx);
        return { jsonrpc: '2.0', id, result: toolResult(out, false) };
      } catch (e) {
        if (e instanceof ToolError) return { jsonrpc: '2.0', id, result: toolResult({ error: e.message }, true) };
        onError(e);
        return { jsonrpc: '2.0', id, result: toolResult({ error: 'something went wrong; try again' }, true) };
      }
    }
    default:
      return error(id, ERR.methodNotFound, `method not found: ${msg.method}`);
  }
}

/** A tool result: the JSON as text (every client reads it) and as structured content. */
export function toolResult(out: unknown, isError: boolean) {
  const structured = out !== null && typeof out === 'object' && !Array.isArray(out) ? out : { value: out };
  return {
    content: [{ type: 'text', text: JSON.stringify(out) }],
    structuredContent: structured,
    ...(isError ? { isError: true } : {}),
  };
}

/**
 * A POST body: one message or a batch. Returns the JSON to send, or null when
 * everything was a notification (the transport answers 202 with no body).
 */
export async function handleBody(
  server: McpServer,
  raw: string,
  ctx: ToolContext,
  onError?: (e: unknown) => void,
): Promise<JsonRpcResponse | JsonRpcResponse[] | null> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return error(null, ERR.parse, 'parse error');
  }
  if (Array.isArray(parsed)) {
    if (parsed.length === 0) return error(null, ERR.invalidRequest, 'empty batch');
    const out = (await Promise.all(parsed.slice(0, 20).map((m) => handleMessage(server, m, ctx, onError))))
      .filter((r): r is JsonRpcResponse => r !== null);
    return out.length ? out : null;
  }
  return handleMessage(server, parsed, ctx, onError);
}

// ── Small argument readers (a tool's own validation) ──────────────────────

export function str(args: Record<string, unknown>, key: string, opts: { max?: number; required?: boolean } = {}): string | undefined {
  const v = args[key];
  if (v === undefined || v === null || v === '') {
    if (opts.required) throw new ToolError(`${key} is required`);
    return undefined;
  }
  if (typeof v !== 'string') throw new ToolError(`${key} must be a string`);
  const s = v.trim();
  if (opts.max && s.length > opts.max) throw new ToolError(`${key} is too long (max ${opts.max})`);
  return s;
}

export function int(args: Record<string, unknown>, key: string, def: number, min: number, max: number): number {
  const v = args[key];
  if (v === undefined || v === null || v === '') return def;
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw new ToolError(`${key} must be a whole number from ${min} to ${max}`);
  return n;
}

export function isoDate(args: Record<string, unknown>, key: string): string | undefined {
  const s = str(args, key, { max: 40 });
  if (s === undefined) return undefined;
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new ToolError(`${key} must be a date (YYYY-MM-DD or ISO 8601)`);
  return new Date(t).toISOString();
}
