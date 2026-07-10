/* PhaseZero UI Dashboard - safe, catalog-driven frontend */
'use strict';

const API_BASE = '/api';
const STATUS_TIMEOUT_MS = 180_000;
const ACTION_TIMEOUT_MS = 31 * 60_000;
let actionsPromise;
let actionMap = new Map();

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, char => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[char]);
}

async function api(method, path, body, timeoutMs = STATUS_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeoutMs);
  try {
    const options = {
      method,
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
      signal: controller.signal,
    };
    if (body !== undefined) {
      options.headers['Content-Type'] = 'application/json';
      options.body = JSON.stringify(body);
    }
    const response = await fetch(`${API_BASE}${path}`, options);
    const contentType = response.headers.get('content-type') || '';
    if (!contentType.includes('application/json')) {
      throw new Error(`Resposta inválida do servidor (HTTP ${response.status})`);
    }
    const data = await response.json();
    if (!response.ok) {
      const detail = (data.blockers || []).join('; ') || `HTTP ${response.status}`;
      throw new Error(detail);
    }
    return data;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('Tempo limite excedido');
    throw error;
  } finally {
    window.clearTimeout(timer);
  }
}

function badge(status) {
  const normalized = String(status || 'warn').toLowerCase();
  const classes = { ok: 'ok', warn: 'warn', blocked: 'blocked', error: 'blocked', running: 'running' };
  return `<span class="badge ${classes[normalized] || 'warn'}">${escapeHtml(normalized)}</span>`;
}

function spinner(label = 'Carregando…') {
  return `<div class="loading" role="status"><span class="spinner"></span>${escapeHtml(label)}</div>`;
}

function errorBlock(error) {
  return `<div class="notice error" role="alert">${escapeHtml(error.message || error)}</div>`;
}

function renderChecks(checks, nameLabel = 'Item') {
  if (!Array.isArray(checks) || checks.length === 0) {
    return '<div class="notice">Nenhum check retornado.</div>';
  }
  const rows = checks.map(check => `<tr>
    <td>${escapeHtml(check.name)}</td>
    <td>${badge(check.status)}</td>
    <td>${escapeHtml(check.message)}</td>
  </tr>`).join('');
  return `<div class="table-wrap"><table><thead><tr><th>${escapeHtml(nameLabel)}</th><th>Status</th><th>Detalhe</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}

function statusCards(data) {
  return `<div class="cards">
    <div class="card"><div class="stat-label">Status</div><div class="stat">${badge(data.status)}</div></div>
    <div class="card"><div class="stat-label">Checks</div><div class="stat">${escapeHtml((data.checks || []).length)}</div></div>
  </div>`;
}

async function allActions() {
  if (!actionsPromise) {
    actionsPromise = api('GET', '/actions').then(data => {
      const actions = Array.isArray(data.actions) ? data.actions : [];
      actionMap = new Map(actions.map(action => [action.name, action]));
      return actions;
    }).catch(error => {
      actionsPromise = undefined;
      throw error;
    });
  }
  return actionsPromise;
}

async function actionsFor(moduleName, predicate = () => true) {
  return (await allActions())
    .filter(action => action.module === moduleName && predicate(action))
    .sort((left, right) => String(left.label).localeCompare(String(right.label), 'pt-BR'));
}

function actionButtons(actions) {
  if (!actions.length) return '<div class="notice">Nenhuma ação disponível.</div>';
  return `<div class="action-section"><h3>Ações</h3><div class="action-grid">${actions.map(action => {
    const variant = action.mutable ? 'danger' : 'secondary';
    return `<button class="btn btn-${variant} btn-sm" type="button" data-action="${escapeHtml(action.name)}">
      ${escapeHtml(action.label || action.name)}
    </button>`;
  }).join('')}</div></div>`;
}

function showPage(id) {
  const page = document.getElementById(id) || document.getElementById('overview');
  document.querySelectorAll('.page').forEach(item => { item.hidden = item !== page; });
  document.querySelectorAll('.sidebar nav a').forEach(link => {
    const active = link.getAttribute('href') === `#${page.id}`;
    link.classList.toggle('active', active);
    if (active) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  });
  const loaders = {
    overview: loadOverview, steamdeck: loadSteamDeck, emulation: loadEmulation,
    media: loadMedia, server: loadServer, ai: loadAI,
    profiles: loadProfiles, doctor: loadDoctor,
  };
  loaders[page.id]?.();
}

async function loadOverview() {
  const container = document.getElementById('overview-content');
  container.innerHTML = spinner('Verificando host…');
  try {
    const data = await api('GET', '/status');
    let allOk = true;
    const cards = Object.entries(data).map(([moduleName, info]) => {
      const status = info.status || 'warn';
      if (status !== 'ok') allOk = false;
      return `<div class="card"><div class="stat-label">${escapeHtml(moduleName)}</div>
        <div class="stat">${badge(status)}</div>
        <div class="card-detail">${escapeHtml((info.checks || []).length)} checks</div></div>`;
    }).join('');
    container.innerHTML = `<div class="cards">${cards}</div>
      <div class="notice"><strong>Status geral:</strong> ${allOk ? `${badge('ok')} Sistema saudável` : `${badge('warn')} Requer atenção`}</div>`;
  } catch (error) { container.innerHTML = errorBlock(error); }
}

async function loadModulePage(containerId, statusModule, catalogModule, predicate = () => true) {
  const container = document.getElementById(containerId);
  container.innerHTML = spinner();
  try {
    const [data, actions] = await Promise.all([
      api('GET', `/status/${statusModule}`), actionsFor(catalogModule, predicate),
    ]);
    container.innerHTML = `${statusCards(data)}${renderChecks(data.checks)}${actionButtons(actions)}`;
  } catch (error) { container.innerHTML = errorBlock(error); }
}

function loadSteamDeck() { return loadModulePage('steamdeck-content', 'steamdeck', 'Steam Deck'); }
function loadEmulation() { return loadModulePage('emulation-content', 'emulation', 'Emulação'); }
function loadServer() { return loadModulePage('server-content', 'server', 'Servidor'); }
function loadAI() { return loadModulePage('ai-content', 'ai', 'IA & Dev'); }

async function loadMedia() {
  const container = document.getElementById('media-content');
  container.innerHTML = spinner();
  try {
    const [data, actions] = await Promise.all([
      api('GET', '/status/emulation'),
      actionsFor('Emulação', action => /\.(media|media-clean|shared|bios|keys|firmware|nsz|ps3-game)$/.test(action.name)),
    ]);
    const checks = (data.checks || []).filter(check => String(check.name || '').startsWith('media.'));
    container.innerHTML = `${statusCards({ status: data.status, checks })}${renderChecks(checks)}${actionButtons(actions)}`;
  } catch (error) { container.innerHTML = errorBlock(error); }
}

async function loadProfiles() {
  const container = document.getElementById('profiles-content');
  container.innerHTML = spinner();
  try {
    const actions = await actionsFor('Perfis');
    const rows = actions.map(action => `<tr><td>${escapeHtml(action.label)}</td><td><button class="btn btn-danger btn-sm" type="button" data-action="${escapeHtml(action.name)}">Pré-visualizar</button></td></tr>`).join('');
    container.innerHTML = `<div class="table-wrap"><table><thead><tr><th>Perfil</th><th>Ação</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  } catch (error) { container.innerHTML = errorBlock(error); }
}

async function loadDoctor() {
  const container = document.getElementById('doctor-content');
  container.innerHTML = spinner();
  try {
    const [data, actions] = await Promise.all([api('GET', '/status/system'), actionsFor('Visão geral')]);
    container.innerHTML = `${statusCards(data)}${renderChecks(data.checks)}${actionButtons(actions)}`;
  } catch (error) { container.innerHTML = errorBlock(error); }
}

function actionOutput(html) {
  const output = document.getElementById('action-output');
  output.innerHTML = html;
  output.hidden = false;
  output.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

function renderActionResult(data) {
  const logs = (data.logs || []).map(log => `<pre class="log-viewer ${escapeHtml(log.level)}">${escapeHtml(log.message)}</pre>`).join('');
  const blockers = (data.blockers || []).map(item => `<li>${escapeHtml(item)}</li>`).join('');
  return `<div class="notice"><div>Status: ${badge(data.status)}</div>${blockers ? `<ul>${blockers}</ul>` : ''}${logs}</div>`;
}

async function runAction(action, inputValue = '') {
  actionOutput(spinner('Executando…'));
  try {
    const data = await api('POST', '/action', {
      action: action.name, confirmed: true, input: inputValue,
    }, ACTION_TIMEOUT_MS);
    actionOutput(renderActionResult(data));
  } catch (error) { actionOutput(errorBlock(error)); }
}

function makeModal(action) {
  document.querySelector('.modal-overlay')?.remove();
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  const modal = document.createElement('div');
  modal.className = 'modal';
  modal.setAttribute('role', 'dialog');
  modal.setAttribute('aria-modal', 'true');
  const title = document.createElement('h3');
  title.textContent = action.mutable ? 'Revisar e confirmar' : 'Executar ação';
  const description = document.createElement('p');
  description.textContent = action.label || action.name;
  modal.append(title, description);

  let input;
  if (action.inputKind) {
    const label = document.createElement('label');
    label.className = 'field-label';
    label.textContent = action.inputLabel || 'Caminho no host';
    input = document.createElement('input');
    input.className = 'path-input';
    input.type = 'text';
    input.autocomplete = 'off';
    input.placeholder = '/caminho/no/host';
    label.appendChild(input);
    modal.appendChild(label);
  }

  const preview = document.createElement('div');
  preview.className = 'modal-preview';
  modal.appendChild(preview);
  const buttons = document.createElement('div');
  buttons.className = 'modal-buttons';
  const cancel = document.createElement('button');
  cancel.className = 'btn btn-secondary';
  cancel.type = 'button';
  cancel.textContent = 'Cancelar';
  cancel.addEventListener('click', () => overlay.remove());
  const confirm = document.createElement('button');
  confirm.className = action.mutable ? 'btn btn-danger' : 'btn btn-primary';
  confirm.type = 'button';
  confirm.textContent = action.mutable ? 'Gerar prévia' : 'Executar';
  buttons.append(cancel, confirm);
  modal.appendChild(buttons);
  overlay.appendChild(modal);
  overlay.addEventListener('click', event => { if (event.target === overlay) overlay.remove(); });
  document.body.appendChild(overlay);
  (input || confirm).focus();
  return { overlay, preview, confirm, input };
}

async function requestAction(action) {
  if (!action.mutable && !action.inputKind) {
    await runAction(action);
    return;
  }
  const ui = makeModal(action);
  if (!action.mutable) {
    ui.confirm.addEventListener('click', () => {
      const value = ui.input?.value.trim() || '';
      if (ui.input && !value) { ui.input.focus(); return; }
      ui.overlay.remove();
      runAction(action, value);
    });
    return;
  }

  ui.confirm.addEventListener('click', async () => {
    const inputValue = ui.input?.value.trim() || '';
    if (ui.input && !inputValue) { ui.input.focus(); return; }
    ui.confirm.disabled = true;
    ui.preview.innerHTML = spinner('Gerando prévia segura…');
    try {
      const data = await api('POST', '/action', {
        action: action.name, confirmed: false, input: inputValue,
      }, ACTION_TIMEOUT_MS);
      ui.preview.innerHTML = renderActionResult(data);
      const apply = ui.confirm.cloneNode(true);
      apply.textContent = 'Confirmar e aplicar';
      apply.disabled = data.status !== 'ok';
      ui.confirm.replaceWith(apply);
      apply.addEventListener('click', () => {
        ui.overlay.remove();
        runAction(action, inputValue);
      }, { once: true });
    } catch (error) {
      ui.preview.innerHTML = errorBlock(error);
      ui.confirm.disabled = false;
    }
  });
}

document.addEventListener('click', event => {
  const button = event.target.closest('[data-action]');
  if (!button) return;
  const action = actionMap.get(button.dataset.action);
  if (action) requestAction(action);
});

document.addEventListener('keydown', event => {
  if (event.key === 'Escape') document.querySelector('.modal-overlay')?.remove();
});

document.addEventListener('DOMContentLoaded', () => {
  function hashRoute() {
    showPage(window.location.hash.slice(1) || 'overview');
  }
  window.addEventListener('hashchange', hashRoute);
  allActions().catch(error => actionOutput(errorBlock(error)));
  hashRoute();
});
