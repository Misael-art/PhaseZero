/* PhaseZero UI Dashboard - frontend logic */
const API_BASE = '/api';
let TOKEN = (document.querySelector('meta[name="token"]')||{}).content || '';

function headers() {
  return {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${TOKEN}`,
  };
}

async function api(method, path, body) {
  const opts = { method, headers: headers() };
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch(`${API_BASE}${path}`, opts);
  return r.json();
}

/* ---- Status rendering helpers ---- */
function badge(status) {
  const map = { ok: 'ok', warn: 'warn', blocked: 'blocked', error: 'blocked', running: 'running' };
  return `<span class="badge ${map[status] || 'warn'}">${status}</span>`;
}

function checkIndicator(status) {
  const colors = { ok: '#00e676', warn: '#ffc107', error: '#ff5252', blocked: '#ff5252' };
  return `<span class="check-indicator" style="background:${colors[status] || '#9090b0'}"></span>`;
}

function el(tag, attrs, ...children) {
  const e = document.createElement(tag);
  if (attrs) for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const c of children) e.append(c);
  return e;
}

/* ---- Page rendering ---- */
function showPage(id) {
  document.querySelectorAll('.page').forEach(p => p.style.display = 'none');
  document.querySelectorAll('.sidebar nav a').forEach(a => a.classList.remove('active'));
  const page = document.getElementById(id);
  if (page) page.style.display = 'block';
  const link = document.querySelector(`.sidebar nav a[href="#${id}"]`);
  if (link) link.classList.add('active');
  if (id === 'overview') loadOverview();
  else if (id === 'steamdeck') loadSteamDeck();
  else if (id === 'emulation') loadEmulation();
  else if (id === 'media') loadMedia();
  else if (id === 'ai') loadAI();
  else if (id === 'profiles') loadProfiles();
  else if (id === 'doctor') loadDoctor();
}

/* ---- Overview ---- */
async function loadOverview() {
  const container = document.getElementById('overview-content');
  container.innerHTML = '<div class="spinner"></div> Loading...';
  try {
    const data = await api('GET', '/status');
    let html = '<div class="cards">';
    let allOk = true;
    for (const [mod, info] of Object.entries(data)) {
      const s = info.status || 'warn';
      if (s !== 'ok') allOk = false;
      html += `<div class="card">
        <div class="stat-label">${mod}</div>
        <div class="stat">${badge(s)}</div>
        <div style="font-size:.75rem;color:var(--text-dim);margin-top:.5rem">${(info.checks||[]).length} checks</div>
      </div>`;
    }
    html += '</div>';
    html += `<div style="padding:1rem;background:var(--surface);border-radius:8px;border:1px solid var(--border)">
      <strong>Status geral:</strong> ${allOk ? badge('ok') + ' Sistema saudável' : badge('warn') + ' Requer atenção'}
    </div>`;
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">Erro: ${e.message}</div>`;
  }
}

/* ---- Steam Deck ---- */
async function loadSteamDeck() {
  const container = document.getElementById('steamdeck-content');
  container.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await api('GET', '/status/steamdeck');
    let html = '<div class="cards">';
    html += `<div class="card"><div class="stat-label">Status</div><div class="stat">${badge(data.status)}</div></div>`;
    html += '</div>';
    if (data.checks && data.checks.length) {
      html += '<table><tr><th>Check</th><th>Status</th><th>Detalhe</th></tr>';
      for (const c of data.checks) html += `<tr><td>${c.name}</td><td>${badge(c.status)}</td><td>${c.message||''}</td></tr>`;
      html += '</table>';
    }
    html += actionButtons('steamdeck', [
      'steamdeck.handheld','steamdeck.docked-tv','steamdeck.docked-monitor',
      'steamdeck.kb','steamdeck.kb-repair',
      'steamdeck.plugins-status','steamdeck.plugins-install','steamdeck.plugins-install-privileged','steamdeck.plugins-install-plugins',
      'steamdeck.plugins-repair','steamdeck.plugins-repair-privileged','steamdeck.plugins-powertools-repair',
      'steamdeck.plugins-install-themes','steamdeck.plugins-enable-cef','steamdeck.plugins-prepare-ui',
      'steamdeck.boot-status','steamdeck.boot-next-reboot'
    ]);
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">${e.message}</div>`;
  }
}

/* ---- Emulation ---- */
async function loadEmulation() {
  const container = document.getElementById('emulation-content');
  container.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await api('GET', '/status/emulation');
    let html = '<div class="cards">';
    html += `<div class="card"><div class="stat-label">Status</div><div class="stat">${badge(data.status)}</div></div>`;
    html += `<div class="card"><div class="stat-label">Checks</div><div class="stat">${(data.checks||[]).length}</div></div>`;
    html += '</div>';
    if (data.checks && data.checks.length) {
      html += '<table><tr><th>Check</th><th>Status</th><th>Detalhe</th></tr>';
      for (const c of data.checks) {
        const name = c.name || '';
        let label = name;
        if (name.startsWith('shared.')) label = name.replace('shared.', 'Compartilhado: ');
        else if (name.startsWith('media.')) label = name.replace('media.', 'Mídia: ');
        html += `<tr><td>${label}</td><td>${badge(c.status)}</td><td>${c.message||''}</td></tr>`;
      }
      html += '</table>';
    }
    html += '<div style="margin-top:1rem"><h3>Ações</h3>';
    html += actionButtons('emulation', [
      'emulation.retrodeck.status','emulation.retrodeck.plan','emulation.retrodeck.integrate','emulation.retrodeck.repair',
      'emulation.shared.status','emulation.shared.plan','emulation.shared.apply',
      'emulation.media.status','emulation.media.index','emulation.media.apply',
      'emulation.performance.status','emulation.performance.apply','emulation.performance.prepare-lsfg',
      'emulation.emudeck.status','emulation.fixes.list'
    ]);
    html += '</div>';
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">${e.message}</div>`;
  }
}

/* ---- Media ---- */
async function loadMedia() {
  const container = document.getElementById('media-content');
  container.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await api('GET', '/status/emulation');
    const mediaChecks = (data.checks||[]).filter(c => c.name.startsWith('media.'));
    let html = '<div class="cards">';
    html += `<div class="card"><div class="stat-label">Status</div><div class="stat">${badge(data.status)}</div></div>`;
    html += `<div class="card"><div class="stat-label">Checks de mídia</div><div class="stat">${mediaChecks.length}</div></div>`;
    html += '</div>';
    if (mediaChecks.length) {
      html += '<table><tr><th>Item</th><th>Status</th><th>Detalhe</th></tr>';
      for (const c of mediaChecks) {
        const name = c.name.replace('media.', '');
        html += `<tr><td>${name}</td><td>${badge(c.status)}</td><td>${c.message||''}</td></tr>`;
      }
      html += '</table>';
    }
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">${e.message}</div>`;
  }
}

/* ---- AI ---- */
async function loadAI() {
  const container = document.getElementById('ai-content');
  container.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await api('GET', '/status/ai');
    let html = '<div class="cards">';
    html += `<div class="card"><div class="stat-label">Status</div><div class="stat">${badge(data.status)}</div></div>`;
    html += '</div>';
    if (data.checks && data.checks.length) {
      html += '<table><tr><th>Check</th><th>Status</th><th>Detalhe</th></tr>';
      for (const c of data.checks) html += `<tr><td>${c.name}</td><td>${badge(c.status)}</td><td>${c.message||''}</td></tr>`;
      html += '</table>';
    }
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">${e.message}</div>`;
  }
}

/* ---- Profiles ---- */
async function loadProfiles() {
  const container = document.getElementById('profiles-content');
  container.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await api('GET', '/actions');
    const profileActions = (data.actions||[]).filter(a => a.name.startsWith('profiles.'));
    let html = '<div class="cards">';
    html += `<div class="card"><div class="stat-label">Profiles disponíveis</div></div>`;
    html += '</div><table><tr><th>Profile</th><th>Descrição</th><th></th></tr>';
    const profiles = ['safe-base','dev-ai','gaming','steamdeck-linux','emulation-linux','homelab','full-workstation'];
    for (const p of profiles) {
      html += `<tr><td>${p}</td><td style="color:var(--text-dim)">Ver descrição</td>
        <td><button class="btn btn-secondary btn-sm" onclick="showPlan('profiles.${p}')">Ver perfil</button></td></tr>`;
    }
    html += '</table>';
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">${e.message}</div>`;
  }
}

/* ---- Doctor ---- */
async function loadDoctor() {
  const container = document.getElementById('doctor-content');
  container.innerHTML = '<div class="spinner"></div>';
  try {
    const data = await api('GET', '/status/system');
    let html = `<div class="cards">
      <div class="card"><div class="stat-label">Sistema</div><div class="stat">${badge(data.status)}</div></div>
    </div>`;
    html += actionButtons('doctor', ['system.doctor','system.repair-plan','system.support-bundle']);
    html += '<div id="doctor-output" style="margin-top:1rem"></div>';
    container.innerHTML = html;
  } catch (e) {
    container.innerHTML = `<div class="badge blocked">${e.message}</div>`;
  }
}

/* ---- Actions ---- */
async function runAction(action, requireConfirm) {
  if (requireConfirm) {
    showConfirmModal(action);
    return;
  }
  const output = document.getElementById('action-output');
  if (output) output.innerHTML = '<div class="spinner"></div> Executando...';
  try {
    const data = await api('POST', '/action', { action, confirmed: true });
    if (output) {
      let html = `<div style="margin-top:1rem;background:var(--surface);padding:1rem;border-radius:8px">
        <div>Status: ${badge(data.status)}</div>`;
      if (data.logs) for (const l of data.logs) {
        html += `<div class="log-viewer"><span class="${l.level}">[${l.level}]</span> ${l.message}</div>`;
      }
      html += '</div>';
      output.innerHTML = html;
    }
  } catch (e) {
    if (output) output.innerHTML = `<div class="badge blocked">Erro: ${e.message}</div>`;
  }
}

function showConfirmModal(action) {
  const existing = document.querySelector('.modal-overlay');
  if (existing) existing.remove();
  const overlay = el('div', { class: 'modal-overlay', onclick: e => { if (e.target === overlay) overlay.remove(); } });
  const modal = el('div', { class: 'modal' });
  modal.innerHTML = `<h3>Confirmar ação</h3>
    <p>Tem certeza que deseja executar <strong>${action}</strong>?</p>
    <p style="font-size:.8rem;color:var(--text-dim);margin-top:.5rem">Ação mutável requer confirmação explícita.</p>
    <div class="modal-buttons">
      <button class="btn btn-secondary" onclick="this.closest('.modal-overlay').remove()">Cancelar</button>
      <button class="btn btn-primary" onclick="runAction('${action}', false); this.closest('.modal-overlay').remove()">Confirmar</button>
    </div>`;
  overlay.appendChild(modal);
  document.body.appendChild(overlay);
}

function actionButtons(module, actions) {
  return `<div style="display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.5rem">
    ${actions.map(a => `<button class="btn btn-${a.includes('apply')||a.includes('install')||a.includes('repair') ? 'danger' : 'secondary'} btn-sm" onclick="runAction('${a}', ${a.includes('apply')||a.includes('install')||a.includes('repair')})">${a.split('.').pop()}</button>`).join('')}
  </div>
  <div id="action-output"></div>`;
}

function showPlan(action) {
  alert(`Plano para ${action}: execute via terminal com\npz ${action.replace('.', ' ')}`);
}

/* ---- Init ---- */
document.addEventListener('DOMContentLoaded', () => {
  // Hash routing
  function hashRoute() {
    const hash = window.location.hash.slice(1) || 'overview';
    showPage(hash);
  }
  window.addEventListener('hashchange', hashRoute);
  // fix template token
  const meta = document.querySelector('meta[name="token"]');
  if (meta) TOKEN = meta.content;
  hashRoute();
});
