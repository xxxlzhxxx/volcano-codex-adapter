#!/usr/bin/env node
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');

const HOST = process.env.OBSERVER_HOST || '127.0.0.1';
const PORT = Number(process.env.OBSERVER_PORT || 17860);
const UPSTREAM_BASE = (process.env.ARK_UPSTREAM_BASE || 'https://ark.cn-beijing.volces.com/api/v3').replace(/\/$/, '');
const LOG_DIR = path.resolve(process.env.OBSERVER_LOG_DIR || path.join(process.cwd(), '.ark-observer'));
const STATIC_DIR = path.join(__dirname, 'public');
const FILTER_REASONING_SUMMARY = process.env.OBSERVER_FILTER_REASONING_SUMMARY === '1';
const MAX_BODY_BYTES = Number(process.env.OBSERVER_MAX_BODY_BYTES || 25 * 1024 * 1024);

const REQUESTS_DIR = path.join(LOG_DIR, 'requests');

function ensureDirs() {
  fs.mkdirSync(REQUESTS_DIR, { recursive: true });
}

function json(res, status, value) {
  const body = JSON.stringify(value, null, 2);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'access-control-allow-origin': '*',
  });
  res.end(body);
}

function text(res, status, value, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'content-type': contentType,
    'content-length': Buffer.byteLength(value),
  });
  res.end(value);
}

function safeFileName(value) {
  return String(value).replace(/[^a-zA-Z0-9_.-]/g, '_');
}

function nowIso() {
  return new Date().toISOString();
}

function requestPrefix(id) {
  return path.join(REQUESTS_DIR, safeFileName(id));
}

function readJsonIfExists(file) {
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function redactHeaders(headers) {
  const redacted = {};
  for (const [key, value] of Object.entries(headers || {})) {
    if (/authorization|api[-_]key|token|cookie/i.test(key)) {
      redacted[key] = '<redacted>';
    } else {
      redacted[key] = value;
    }
  }
  return redacted;
}

function parseJsonMaybe(value) {
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

function parseSseBlock(block) {
  let event = '';
  const data = [];
  for (const line of block.split(/\r?\n/)) {
    if (line.startsWith('event:')) {
      event = line.slice(6).trim();
    } else if (line.startsWith('data:')) {
      data.push(line.slice(5).trimStart());
    }
  }
  return { event, data: data.join('\n') };
}

function formatSseBlock(event, data) {
  const lines = [];
  if (event) lines.push(`event: ${event}`);
  if (data) {
    for (const line of data.split('\n')) {
      lines.push(`data: ${line}`);
    }
  }
  return `${lines.join('\n')}\n\n`;
}

function collectRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error(`request body exceeds ${MAX_BODY_BYTES} bytes`));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function makeInitialSummary(id, req, parsedBody, bodyBytes) {
  return {
    request_id: id,
    started_at: nowIso(),
    completed_at: null,
    method: req.method,
    path: req.url,
    upstream_url: `${UPSTREAM_BASE}/responses`,
    status: null,
    model: parsedBody?.model || null,
    input_items: Array.isArray(parsedBody?.input) ? parsedBody.input.length : null,
    tool_count: Array.isArray(parsedBody?.tools) ? parsedBody.tools.length : 0,
    request_body_bytes: bodyBytes,
    response_bytes: 0,
    event_count: 0,
    event_types: {},
    latency_ms: null,
    first_event_ms: null,
    ttft_ms: null,
    completed_event_ms: null,
    input_tokens: null,
    output_tokens: null,
    total_tokens: null,
    cached_tokens: null,
    cache_write_tokens: null,
    cache_hit_ratio: null,
    output_text_preview: '',
    tool_calls: [],
    errors: [],
    filtered_reasoning_summary: FILTER_REASONING_SUMMARY,
  };
}

function updateUsage(summary, usage) {
  if (!usage || typeof usage !== 'object') return;
  summary.input_tokens = usage.input_tokens ?? summary.input_tokens;
  summary.output_tokens = usage.output_tokens ?? summary.output_tokens;
  summary.total_tokens = usage.total_tokens ?? summary.total_tokens;

  const inputDetails = usage.input_tokens_details || {};
  summary.cached_tokens = inputDetails.cached_tokens ?? inputDetails.cache_read_tokens ?? summary.cached_tokens;
  summary.cache_write_tokens =
    inputDetails.cache_write_tokens ??
    inputDetails.cache_write_input_tokens ??
    usage.cache_write_tokens ??
    usage.cache_write_input_tokens ??
    summary.cache_write_tokens;
  if (summary.input_tokens && summary.cached_tokens != null) {
    summary.cache_hit_ratio = Number((summary.cached_tokens / summary.input_tokens).toFixed(4));
  }
}

function observeEvent(summary, eventName, payload, elapsedMs) {
  summary.event_count += 1;
  summary.event_types[eventName || '<none>'] = (summary.event_types[eventName || '<none>'] || 0) + 1;
  if (summary.first_event_ms == null) summary.first_event_ms = elapsedMs;

  if (!payload || typeof payload !== 'object') return;

  if (eventName === 'response.output_text.delta') {
    if (summary.ttft_ms == null) summary.ttft_ms = elapsedMs;
    summary.output_text_preview = `${summary.output_text_preview}${payload.delta || ''}`.slice(0, 5000);
  }

  if (eventName === 'response.function_call_arguments.delta' && summary.ttft_ms == null) {
    summary.ttft_ms = elapsedMs;
  }

  if (eventName === 'response.output_item.added' || eventName === 'response.output_item.done') {
    const item = payload.item;
    if (item && item.type === 'function_call') {
      const existing = summary.tool_calls.find((call) => call.call_id === item.call_id);
      const next = {
        call_id: item.call_id || null,
        name: item.name || null,
        arguments: item.arguments || '',
        status: item.status || null,
      };
      if (existing) Object.assign(existing, next);
      else summary.tool_calls.push(next);
    }
  }

  if (eventName === 'response.completed') {
    summary.completed_event_ms = elapsedMs;
    summary.completed_at = nowIso();
    if (payload.response?.model) summary.model = payload.response.model;
    updateUsage(summary, payload.response?.usage);
  }
}

function listSummaries() {
  ensureDirs();
  return fs.readdirSync(REQUESTS_DIR)
    .filter((name) => name.endsWith('.summary.json'))
    .map((name) => readJsonIfExists(path.join(REQUESTS_DIR, name)))
    .filter(Boolean)
    .sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
}

function loadEvents(id) {
  const file = `${requestPrefix(id)}.events.jsonl`;
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => parseJsonMaybe(line))
    .filter(Boolean);
}

function serveStatic(req, res) {
  const urlPath = req.url === '/' ? '/index.html' : decodeURIComponent(req.url.split('?')[0]);
  const file = path.normalize(path.join(STATIC_DIR, urlPath));
  if (!file.startsWith(STATIC_DIR)) {
    text(res, 403, 'Forbidden');
    return;
  }
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    text(res, 404, 'Not found');
    return;
  }
  const ext = path.extname(file);
  const type = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
  }[ext] || 'application/octet-stream';
  const body = fs.readFileSync(file);
  res.writeHead(200, { 'content-type': type, 'content-length': body.length });
  res.end(body);
}

async function handleProxy(req, res) {
  const requestId = `${new Date().toISOString().replace(/[-:.TZ]/g, '').slice(0, 14)}-${randomUUID().slice(0, 8)}`;
  const started = Date.now();
  const prefix = requestPrefix(requestId);
  const eventsStream = fs.createWriteStream(`${prefix}.events.jsonl`, { flags: 'a' });

  try {
    const body = await collectRequestBody(req);
    const parsedBody = parseJsonMaybe(body.toString('utf8'));
    const summary = makeInitialSummary(requestId, req, parsedBody, body.length);

    fs.writeFileSync(`${prefix}.request.json`, JSON.stringify({
      request_id: requestId,
      captured_at: nowIso(),
      headers: redactHeaders(req.headers),
      body: parsedBody || body.toString('utf8'),
    }, null, 2));

    const upstreamHeaders = {
      'content-type': req.headers['content-type'] || 'application/json',
      'accept': req.headers.accept || 'text/event-stream',
      'user-agent': req.headers['user-agent'] || process.env.USER_AGENT || 'volcano-codex-observer/0.1',
    };
    const auth = req.headers.authorization || (process.env.ARK_API_KEY ? `Bearer ${process.env.ARK_API_KEY}` : null);
    if (auth) upstreamHeaders.authorization = auth;

    const upstream = await fetch(`${UPSTREAM_BASE}/responses`, {
      method: 'POST',
      headers: upstreamHeaders,
      body,
    });

    summary.status = upstream.status;
    res.writeHead(upstream.status, {
      'content-type': upstream.headers.get('content-type') || 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache',
      'x-observer-request-id': requestId,
    });

    let pending = '';
    for await (const chunk of upstream.body) {
      const textChunk = Buffer.from(chunk).toString('utf8').replace(/\r\n/g, '\n');
      pending += textChunk;
      summary.response_bytes += Buffer.byteLength(textChunk);

      let splitAt;
      while ((splitAt = pending.indexOf('\n\n')) >= 0) {
        const block = pending.slice(0, splitAt);
        pending = pending.slice(splitAt + 2);
        if (!block.trim()) continue;

        const parsed = parseSseBlock(block);
        const payload = parseJsonMaybe(parsed.data);
        const eventName = parsed.event || payload?.type || '';
        const elapsedMs = Date.now() - started;

        eventsStream.write(JSON.stringify({
          ts: nowIso(),
          elapsed_ms: elapsedMs,
          event: eventName,
          data: payload || parsed.data,
        }) + '\n');
        observeEvent(summary, eventName, payload, elapsedMs);

        if (FILTER_REASONING_SUMMARY && eventName.startsWith('response.reasoning_summary')) {
          continue;
        }
        res.write(formatSseBlock(parsed.event, parsed.data));
      }
    }

    if (pending.length > 0) {
      res.write(pending);
      eventsStream.write(JSON.stringify({
        ts: nowIso(),
        elapsed_ms: Date.now() - started,
        event: '<trailing-bytes>',
        data: pending,
      }) + '\n');
    }

    summary.latency_ms = Date.now() - started;
    summary.completed_at = summary.completed_at || nowIso();
    fs.writeFileSync(`${prefix}.summary.json`, JSON.stringify(summary, null, 2));
    eventsStream.end();
    res.end();
  } catch (error) {
    const summary = readJsonIfExists(`${prefix}.summary.json`) || {
      request_id: requestId,
      started_at: new Date(started).toISOString(),
      errors: [],
    };
    summary.status = summary.status || 500;
    summary.completed_at = nowIso();
    summary.latency_ms = Date.now() - started;
    summary.errors.push(String(error.stack || error.message || error));
    fs.writeFileSync(`${prefix}.summary.json`, JSON.stringify(summary, null, 2));
    eventsStream.end();
    if (!res.headersSent) {
      json(res, 500, { error: String(error.message || error), request_id: requestId });
    } else {
      res.end();
    }
  }
}

async function router(req, res) {
  ensureDirs();

  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'access-control-allow-origin': '*',
      'access-control-allow-methods': 'GET,POST,OPTIONS',
      'access-control-allow-headers': 'content-type,authorization,user-agent',
    });
    res.end();
    return;
  }

  const url = new URL(req.url, `http://${req.headers.host || `${HOST}:${PORT}`}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    json(res, 200, {
      ok: true,
      upstream_base: UPSTREAM_BASE,
      log_dir: LOG_DIR,
      filter_reasoning_summary: FILTER_REASONING_SUMMARY,
    });
    return;
  }

  if (req.method === 'GET' && url.pathname === '/api/requests') {
    json(res, 200, { requests: listSummaries() });
    return;
  }

  if (req.method === 'GET' && url.pathname.startsWith('/api/requests/')) {
    const id = path.basename(url.pathname);
    const summary = readJsonIfExists(`${requestPrefix(id)}.summary.json`);
    if (!summary) {
      json(res, 404, { error: 'request not found' });
      return;
    }
    json(res, 200, {
      summary,
      request: readJsonIfExists(`${requestPrefix(id)}.request.json`),
      events: loadEvents(id),
    });
    return;
  }

  if (req.method === 'POST' && url.pathname === '/api/v3/responses') {
    await handleProxy(req, res);
    return;
  }

  if (req.method === 'POST' && url.pathname === '/responses') {
    await handleProxy(req, res);
    return;
  }

  if (req.method === 'GET') {
    serveStatic(req, res);
    return;
  }

  json(res, 404, { error: 'not found' });
}

ensureDirs();
const server = http.createServer((req, res) => {
  router(req, res).catch((error) => {
    json(res, 500, { error: String(error.stack || error.message || error) });
  });
});

server.listen(PORT, HOST, () => {
  console.log(`Volcano Codex Observer`);
  console.log(`  dashboard: http://${HOST}:${PORT}/`);
  console.log(`  proxy:     http://${HOST}:${PORT}/api/v3/responses`);
  console.log(`  upstream:  ${UPSTREAM_BASE}/responses`);
  console.log(`  logs:      ${LOG_DIR}`);
  if (FILTER_REASONING_SUMMARY) {
    console.log(`  filter:    response.reasoning_summary_* events`);
  }
});
