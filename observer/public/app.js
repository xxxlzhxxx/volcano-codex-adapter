'use strict';

const state = {
  requests: [],
  selectedId: null,
  timer: null,
};

const $ = (selector) => document.querySelector(selector);
const listEl = $('#request-list');
const detailEl = $('#detail');
const metricsEl = $('#metrics');
const template = $('#request-row-template');

function fmtNumber(value) {
  if (value == null || Number.isNaN(Number(value))) return '-';
  return new Intl.NumberFormat('en-US').format(value);
}

function fmtMs(value) {
  if (value == null) return '-';
  if (value >= 1000) return `${(value / 1000).toFixed(2)}s`;
  return `${Math.round(value)}ms`;
}

function fmtPct(value) {
  if (value == null) return '-';
  return `${Math.round(value * 100)}%`;
}

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function setHealth(ok, detail) {
  $('#health-label').textContent = ok ? 'Proxy online' : 'Proxy unreachable';
  $('#health-detail').textContent = detail;
  document.querySelector('.pulse').style.background = ok ? 'var(--green)' : 'var(--red)';
}

function filteredRequests() {
  const query = $('#search').value.trim().toLowerCase();
  if (!query) return state.requests;
  return state.requests.filter((req) => {
    const haystack = [
      req.request_id,
      req.model,
      req.status,
      req.started_at,
      ...(req.tool_calls || []).map((call) => call.name),
    ].join(' ').toLowerCase();
    return haystack.includes(query);
  });
}

function renderMetrics() {
  const requests = state.requests;
  const totalTokens = requests.reduce((sum, req) => sum + Number(req.total_tokens || 0), 0);
  const ttfts = requests.map((req) => req.ttft_ms).filter((value) => value != null);
  const cacheHits = requests.map((req) => req.cache_hit_ratio).filter((value) => value != null);
  const avgTtft = ttfts.length ? ttfts.reduce((a, b) => a + b, 0) / ttfts.length : null;
  const avgCache = cacheHits.length ? cacheHits.reduce((a, b) => a + b, 0) / cacheHits.length : null;

  const values = [
    fmtNumber(requests.length),
    fmtNumber(totalTokens),
    fmtMs(avgTtft),
    fmtPct(avgCache),
  ];
  metricsEl.querySelectorAll('strong').forEach((node, index) => {
    node.textContent = values[index];
  });
}

function renderList() {
  listEl.innerHTML = '';
  const requests = filteredRequests();

  if (!requests.length) {
    listEl.innerHTML = '<div class="empty"><p>No captured requests.</p></div>';
    return;
  }

  for (const req of requests) {
    const row = template.content.firstElementChild.cloneNode(true);
    row.classList.toggle('active', req.request_id === state.selectedId);
    row.querySelector('.row-id').textContent = req.request_id;
    const status = row.querySelector('.row-status');
    status.textContent = req.status || 'open';
    status.classList.toggle('error', Number(req.status || 0) >= 400 || (req.errors || []).length > 0);
    row.querySelector('.row-meta').textContent = [
      req.model || 'unknown model',
      `${fmtNumber(req.total_tokens)} tok`,
      `TTFT ${fmtMs(req.ttft_ms)}`,
      req.started_at || '',
    ].join(' | ');
    row.addEventListener('click', () => selectRequest(req.request_id));
    listEl.appendChild(row);
  }
}

function mini(label, value) {
  return `<article class="mini"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></article>`;
}

function renderToolCalls(calls) {
  if (!calls || !calls.length) return '<pre>No tool calls captured.</pre>';
  return calls.map((call) => `
    <div class="tool-call">
      <b>${escapeHtml(call.name || 'unknown')}</b>
      <div>call_id: ${escapeHtml(call.call_id || '-')}</div>
      <div>status: ${escapeHtml(call.status || '-')}</div>
      <pre>${escapeHtml(call.arguments || '{}')}</pre>
    </div>
  `).join('');
}

function renderEvents(events) {
  if (!events || !events.length) return '<pre>No events captured.</pre>';
  return `<div class="event-list">${events.slice(-220).map((event) => `
    <div class="event">
      <b>${escapeHtml(event.event)}</b>
      <small>${fmtMs(event.elapsed_ms)}</small>
      <div>${escapeHtml(JSON.stringify(event.data).slice(0, 520))}</div>
    </div>
  `).join('')}</div>`;
}

async function selectRequest(id) {
  state.selectedId = id;
  renderList();
  detailEl.innerHTML = '<div class="empty"><p>Loading request...</p></div>';

  const response = await fetch(`/api/requests/${encodeURIComponent(id)}`);
  const data = await response.json();
  const req = data.summary;
  const eventTypes = Object.entries(req.event_types || {})
    .sort((a, b) => b[1] - a[1])
    .map(([name, count]) => `${name}: ${count}`)
    .join('\n');

  detailEl.innerHTML = `
    <h2>${escapeHtml(req.request_id)}</h2>
    <p class="lede">${escapeHtml(req.model || 'unknown model')} via ${escapeHtml(req.upstream_url || '')}</p>

    <div class="detail-grid">
      ${mini('Status', req.status || '-')}
      ${mini('Latency', fmtMs(req.latency_ms))}
      ${mini('TTFT', fmtMs(req.ttft_ms))}
      ${mini('Input', fmtNumber(req.input_tokens))}
      ${mini('Output', fmtNumber(req.output_tokens))}
      ${mini('Total', fmtNumber(req.total_tokens))}
      ${mini('Cached', fmtNumber(req.cached_tokens))}
      ${mini('Cache Hit', fmtPct(req.cache_hit_ratio))}
      ${mini('Cache Write', fmtNumber(req.cache_write_tokens))}
    </div>

    <div class="section-title">Output Preview</div>
    <pre>${escapeHtml(req.output_text_preview || 'No text preview captured.')}</pre>

    <div class="section-title">Tool Calls</div>
    ${renderToolCalls(req.tool_calls)}

    <div class="section-title">Event Histogram</div>
    <pre>${escapeHtml(eventTypes || 'No event histogram.')}</pre>

    <div class="section-title">Request Body</div>
    <pre>${escapeHtml(JSON.stringify(data.request?.body || {}, null, 2))}</pre>

    <div class="section-title">Raw SSE Events</div>
    ${renderEvents(data.events)}
  `;
}

async function load() {
  try {
    const [health, requests] = await Promise.all([
      fetch('/health').then((res) => res.json()),
      fetch('/api/requests').then((res) => res.json()),
    ]);
    state.requests = requests.requests || [];
    setHealth(Boolean(health.ok), `${health.upstream_base} | ${health.log_dir}`);
    renderMetrics();
    renderList();
    if (state.selectedId && state.requests.some((req) => req.request_id === state.selectedId)) {
      await selectRequest(state.selectedId);
    }
  } catch (error) {
    setHealth(false, String(error.message || error));
  }
}

function configureRefresh() {
  if (state.timer) clearInterval(state.timer);
  const interval = Number($('#refresh').value);
  if (interval > 0) state.timer = setInterval(load, interval);
}

$('#reload').addEventListener('click', load);
$('#search').addEventListener('input', renderList);
$('#refresh').addEventListener('change', configureRefresh);

configureRefresh();
load();
