// Server Maintenance Dashboard – pure vanilla JS, no build step.
// Reads ./data/latest.json (current snapshot) and ./data/history.jsonl (compact time-series).

const fmtBytes = n => {
  if (n == null || isNaN(n)) return '–';
  const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let i = 0; let v = Number(n);
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(v >= 100 ? 0 : 1)} ${u[i]}`;
};
const fmtUptime = sec => {
  if (!sec) return '–';
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  return `${d}d ${h}h`;
};
const fmtAge = h => {
  if (h == null) return '–';
  if (h < 1) return '< 1 h';
  if (h < 48) return `${h} h`;
  return `${Math.floor(h / 24)} d`;
};
const el = (sel) => document.querySelector(sel);
const html = (s) => s; // marker

// ---- tabs
document.querySelectorAll('.tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('tab-' + btn.dataset.tab).classList.add('active');
  });
});

// ---- range selector
let rangeHours = 168;
document.querySelectorAll('.range').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.range').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    rangeHours = Number(btn.dataset.hours);
    drawCharts();
  });
});

let LATEST = null;
let HISTORY = [];

async function load() {
  try {
    const [l, hRes] = await Promise.all([
      fetch('./data/latest.json', { cache: 'no-cache' }),
      fetch('./data/history.jsonl', { cache: 'no-cache' })
    ]);
    if (l.ok) LATEST = await l.json();
    if (hRes.ok) {
      const txt = await hRes.text();
      HISTORY = txt.split('\n').filter(Boolean).map(line => {
        try { return JSON.parse(line); } catch { return null; }
      }).filter(Boolean);
    }
  } catch (e) {
    console.error('load failed', e);
  }
  if (!LATEST) {
    document.querySelector('main').innerHTML =
      '<div class="empty">No metrics yet. Trigger the <code>Collect Dashboard Metrics</code> workflow once to populate <code>docs/data/latest.json</code>.</div>';
    return;
  }
  renderHeader();
  renderStatus();
  renderRisks();
  drawCharts();
}

// ---- header

function renderHeader() {
  el('#host').textContent = LATEST.server.host.name + ' · ' + LATEST.server.host.os;
  const ts = new Date(LATEST.collected_at || LATEST.ts);
  el('#snapshot-ts').textContent = 'snapshot ' + ts.toLocaleString();
  const risks = computeRisks();
  const bad = risks.filter(r => r.severity === 'bad').length;
  const warn = risks.filter(r => r.severity === 'warn').length;
  const pill = el('#overall-pill');
  if (bad) { pill.className = 'pill pill-bad'; pill.textContent = `${bad} critical, ${warn} warnings`; }
  else if (warn) { pill.className = 'pill pill-warn'; pill.textContent = `${warn} warning${warn>1?'s':''}`; }
  else { pill.className = 'pill pill-ok'; pill.textContent = 'all systems normal'; }
}

// ---- status tab

function renderStatus() {
  const sites = LATEST.sites || [];
  el('#sites-grid').innerHTML = sites.length ? sites.map(s => {
    const cls = s.ok ? 'ok' : 'bad';
    return `<div class="card">
      <div class="title">
        <span class="name"><span class="dot ${cls}"></span>${s.host}</span>
        <span class="muted">${s.status || '—'}</span>
      </div>
      <div class="sub">${(s.response_time_s || 0).toFixed(2)} s · cert ${s.cert_days_left ?? '?'} d</div>
    </div>`;
  }).join('') : '<div class="empty">No site data.</div>';

  const containers = LATEST.server.containers || [];
  el('#containers-grid').innerHTML = containers.length ? containers.map(c => {
    let cls = 'ok';
    if (c.state !== 'running') cls = 'bad';
    else if (c.health === 'unhealthy') cls = 'bad';
    else if (c.restart_count > 5) cls = 'warn';
    const startedAge = c.started ? Math.floor((Date.now() - new Date(c.started).getTime()) / 3600000) : null;
    return `<div class="card">
      <div class="title">
        <span class="name"><span class="dot ${cls}"></span>${c.name}</span>
        <span class="muted">${c.state}${c.health !== 'none' ? ' · ' + c.health : ''}</span>
      </div>
      <div class="sub">${c.image} · uptime ${fmtAge(startedAge)} · ${c.restart_count} restart${c.restart_count===1?'':'s'}</div>
      <div class="metrics">
        <div><div class="k">CPU</div><div class="v">${(c.cpu_pct||0).toFixed(1)}%</div></div>
        <div><div class="k">Memory</div><div class="v">${(c.mem_pct||0).toFixed(1)}%</div></div>
      </div>
    </div>`;
  }).join('') : '<div class="empty">No container data.</div>';

  const s = LATEST.server;
  const rootDisk = (s.disks || []).find(d => d.mount === '/') || s.disks?.[0];
  const memPct = s.memory.total_mib ? (s.memory.used_mib * 100 / s.memory.total_mib) : 0;
  const diskPct = rootDisk ? rootDisk.use_pct : 0;
  el('#system-summary').innerHTML = `
    <div class="card"><div class="title"><span class="name">Uptime</span></div>
      <div class="sub">kernel ${s.host.kernel} · ${s.host.cpus} CPU</div>
      <div class="metrics"><div><div class="k">since boot</div><div class="v">${fmtUptime(s.host.uptime_seconds)}</div></div>
      <div><div class="k">load 1/5/15</div><div class="v">${s.cpu.load1} / ${s.cpu.load5} / ${s.cpu.load15}</div></div></div>
    </div>
    <div class="card"><div class="title"><span class="name">Memory</span></div>
      <div class="sub">${s.memory.used_mib} / ${s.memory.total_mib} MiB used</div>
      <div class="metrics"><div><div class="k">used</div><div class="v">${memPct.toFixed(0)}%</div></div>
      <div><div class="k">swap</div><div class="v">${s.memory.swap_used_mib}/${s.memory.swap_total_mib} MiB</div></div></div>
    </div>
    <div class="card"><div class="title"><span class="name">Disk (${rootDisk?.mount || '/'})</span></div>
      <div class="sub">${fmtBytes(rootDisk?.used)} / ${fmtBytes(rootDisk?.size)}</div>
      <div class="metrics"><div><div class="k">used</div><div class="v">${diskPct}%</div></div>
      <div><div class="k">free</div><div class="v">${fmtBytes(rootDisk?.avail)}</div></div></div>
    </div>
    <div class="card"><div class="title"><span class="name">Latest backup</span></div>
      <div class="sub">${s.backups.latest_name || '—'}</div>
      <div class="metrics"><div><div class="k">age</div><div class="v">${fmtAge(s.backups.latest_age_hours)}</div></div>
      <div><div class="k">total on disk</div><div class="v">${fmtBytes(s.backups.total_bytes)}</div></div></div>
    </div>
    <div class="card"><div class="title"><span class="name">Databases</span></div>
      <div class="sub">${(s.databases || []).map(d => `${d.name}: ${fmtBytes(d.size)}`).join(' · ') || '—'}</div>
    </div>
    <div class="card"><div class="title"><span class="name">Security</span></div>
      <div class="sub">UFW ${s.security.ufw_enabled ? 'enabled' : 'DISABLED'} · ${s.security.ufw_rules} rules</div>
      <div class="metrics"><div><div class="k">f2b banned</div><div class="v">${s.security.fail2ban_currently_banned}</div></div>
      <div><div class="k">SSH fails 24h</div><div class="v">${s.security.ssh_failed_logins_24h}</div></div></div>
    </div>
  `;
}

// ---- risks tab

function computeRisks() {
  const risks = [];
  const s = LATEST.server;

  if (s.os_updates.reboot_required) {
    risks.push({ severity: 'bad', label: 'Reboot required', desc: 'Kernel or critical package updated; restart to apply.' });
  }
  if (s.os_updates.security > 0) {
    risks.push({ severity: 'bad', label: `${s.os_updates.security} pending security update${s.os_updates.security>1?'s':''}`,
      desc: 'Run the weekly-update workflow or apt upgrade as soon as possible.' });
  } else if (s.os_updates.pending > 0) {
    risks.push({ severity: 'warn', label: `${s.os_updates.pending} pending OS update${s.os_updates.pending>1?'s':''}`,
      desc: 'Will be picked up by the next weekly update run.' });
  }

  const ageH = s.backups.latest_age_hours;
  if (ageH == null) {
    risks.push({ severity: 'bad', label: 'No backups found', desc: 'Backup directory is empty or missing.' });
  } else if (ageH > 48) {
    risks.push({ severity: 'bad', label: `Backup is ${fmtAge(ageH)} old`, desc: 'Daily backup workflow may be failing.' });
  } else if (ageH > 30) {
    risks.push({ severity: 'warn', label: `Backup is ${fmtAge(ageH)} old`, desc: 'Verify the daily backup ran today.' });
  }

  for (const c of (s.containers || [])) {
    if (c.state !== 'running') {
      risks.push({ severity: 'bad', label: `Container ${c.name} is ${c.state}`, desc: `Image ${c.image}, exit ${c.exit_code}.` });
    } else if (c.health === 'unhealthy') {
      risks.push({ severity: 'bad', label: `Container ${c.name} is unhealthy`, desc: 'Health check is failing.' });
    } else if (c.restart_count > 5) {
      risks.push({ severity: 'warn', label: `Container ${c.name} restarted ${c.restart_count}×`, desc: 'Look for a crash loop.' });
    }
  }

  for (const d of (s.disks || [])) {
    if (d.use_pct >= 90) risks.push({ severity: 'bad', label: `${d.mount} is ${d.use_pct}% full`, desc: `${fmtBytes(d.avail)} free of ${fmtBytes(d.size)}.` });
    else if (d.use_pct >= 80) risks.push({ severity: 'warn', label: `${d.mount} is ${d.use_pct}% full`, desc: `${fmtBytes(d.avail)} free.` });
  }

  if (s.memory.avail_mib != null && s.memory.avail_mib < 200) {
    risks.push({ severity: 'bad', label: `Low memory: ${s.memory.avail_mib} MiB available`, desc: 'Risk of OOM kills.' });
  }
  if (s.memory.swap_total_mib > 0 && s.memory.swap_used_mib / s.memory.swap_total_mib > 0.5) {
    risks.push({ severity: 'warn', label: 'Swap is more than 50% used', desc: 'Memory pressure.' });
  }

  if (!s.security.ufw_enabled) {
    risks.push({ severity: 'bad', label: 'UFW firewall is disabled', desc: 'Re-run scripts/harden-server.sh.' });
  }
  if (s.security.ssh_failed_logins_24h > 50) {
    risks.push({ severity: 'warn', label: `${s.security.ssh_failed_logins_24h} failed SSH logins in 24 h`, desc: 'fail2ban should ban offenders; review auth.log.' });
  }
  if (s.security.fail2ban_currently_banned > 0) {
    risks.push({ severity: 'info', label: `${s.security.fail2ban_currently_banned} IP${s.security.fail2ban_currently_banned>1?'s':''} currently banned`, desc: 'fail2ban is doing its job.' });
  }

  for (const site of (LATEST.sites || [])) {
    if (site.cert_days_left == null) continue;
    if (site.cert_days_left < 14) risks.push({ severity: 'bad', label: `${site.host} TLS expires in ${site.cert_days_left} d`, desc: 'Renewal failed.' });
    else if (site.cert_days_left < 30) risks.push({ severity: 'warn', label: `${site.host} TLS expires in ${site.cert_days_left} d`, desc: 'Verify auto-renewal.' });
  }
  for (const site of (LATEST.sites || [])) {
    if (!site.ok) risks.push({ severity: 'bad', label: `${site.host} returned ${site.status}`, desc: 'Site is down or upstream is failing.' });
  }

  return risks;
}

function renderRisks() {
  const risks = computeRisks();
  const bad = risks.filter(r => r.severity === 'bad').length;
  const warn = risks.filter(r => r.severity === 'warn').length;
  const info = risks.filter(r => r.severity === 'info').length;
  el('#risks-summary').innerHTML = `
    <div class="box bad"><div class="n">${bad}</div><div class="l">critical</div></div>
    <div class="box warn"><div class="n">${warn}</div><div class="l">warnings</div></div>
    <div class="box ok"><div class="n">${info}</div><div class="l">info</div></div>
  `;
  const list = el('#risks-list');
  if (!risks.length) {
    list.innerHTML = '<div class="empty">No risks detected.</div>';
  } else {
    list.innerHTML = risks.map(r =>
      `<div class="risk ${r.severity}"><div><div class="label">${r.label}</div><div class="desc">${r.desc}</div></div></div>`
    ).join('');
  }

  const certs = (LATEST.sites || []).filter(s => s.cert_days_left != null)
    .sort((a,b) => a.cert_days_left - b.cert_days_left);
  el('#cert-table').innerHTML = `
    <thead><tr><th>Host</th><th>Days left</th><th>Status</th></tr></thead>
    <tbody>${certs.map(s => {
      let cls = 'ok'; if (s.cert_days_left < 14) cls = 'bad'; else if (s.cert_days_left < 30) cls = 'warn';
      return `<tr><td>${s.host}</td><td>${s.cert_days_left}</td><td><span class="dot ${cls}"></span>${cls}</td></tr>`;
    }).join('')}</tbody>`;

  const images = LATEST.server.images || [];
  el('#images-table').innerHTML = `
    <thead><tr><th>Image</th><th>Created</th><th>Size</th></tr></thead>
    <tbody>${images.slice(0, 30).map(i =>
      `<tr><td>${i.image}</td><td>${i.created}</td><td>${i.size}</td></tr>`
    ).join('') || '<tr><td colspan="3" class="muted">No image data.</td></tr>'}</tbody>`;
}

// ---- charts

const chartInstances = {};

function filteredHistory() {
  if (!rangeHours) return HISTORY;
  const cutoff = Date.now() - rangeHours * 3600 * 1000;
  return HISTORY.filter(r => new Date(r.ts).getTime() >= cutoff);
}

function lineChart(canvasId, datasets, opts = {}) {
  const ctx = document.getElementById(canvasId);
  if (!ctx) return;
  if (chartInstances[canvasId]) chartInstances[canvasId].destroy();
  const data = filteredHistory();
  chartInstances[canvasId] = new Chart(ctx, {
    type: 'line',
    data: {
      labels: data.map(d => new Date(d.ts)),
      datasets: datasets.map(ds => ({
        label: ds.label,
        data: data.map(d => ds.fn(d)),
        borderColor: ds.color,
        backgroundColor: ds.color + '33',
        borderWidth: 2,
        pointRadius: 0,
        tension: 0.25,
        spanGaps: true,
        fill: ds.fill || false,
      }))
    },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#8a96a6', boxWidth: 12 } },
        tooltip: { mode: 'index', intersect: false }
      },
      scales: {
        x: { type: 'time', time: { tooltipFormat: 'MMM d, HH:mm' }, ticks: { color: '#8a96a6', maxTicksLimit: 6 }, grid: { color: '#2c3645' } },
        y: { ticks: { color: '#8a96a6' }, grid: { color: '#2c3645' }, beginAtZero: opts.zero !== false }
      }
    }
  });
}

// Time-scale needs date adapter; we'll polyfill a minimal one.
// To avoid pulling another lib, use a category x axis fallback.
function categoryChart(canvasId, datasets, opts = {}) {
  const ctx = document.getElementById(canvasId);
  if (!ctx) return;
  if (chartInstances[canvasId]) chartInstances[canvasId].destroy();
  const data = filteredHistory();
  const labels = data.map(d => {
    const dt = new Date(d.ts);
    return `${(dt.getMonth()+1).toString().padStart(2,'0')}-${dt.getDate().toString().padStart(2,'0')} ${dt.getHours().toString().padStart(2,'0')}:00`;
  });
  chartInstances[canvasId] = new Chart(ctx, {
    type: 'line',
    data: {
      labels,
      datasets: datasets.map(ds => ({
        label: ds.label,
        data: data.map(d => ds.fn(d)),
        borderColor: ds.color,
        backgroundColor: ds.color + '33',
        borderWidth: 2,
        pointRadius: 0,
        tension: 0.25,
        spanGaps: true,
        fill: ds.fill || false,
      }))
    },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#8a96a6', boxWidth: 12 } },
        tooltip: { mode: 'index', intersect: false }
      },
      scales: {
        x: { ticks: { color: '#8a96a6', maxTicksLimit: 8, autoSkip: true }, grid: { color: '#2c3645' } },
        y: { ticks: { color: '#8a96a6' }, grid: { color: '#2c3645' }, beginAtZero: opts.zero !== false }
      }
    }
  });
}

function netRateSeries() {
  const h = filteredHistory();
  const out = [];
  for (let i = 1; i < h.length; i++) {
    const prev = h[i-1], cur = h[i];
    const dt = (new Date(cur.ts).getTime() - new Date(prev.ts).getTime()) / 1000;
    if (dt <= 0) { out.push({ rx: 0, tx: 0 }); continue; }
    out.push({
      rx: Math.max(0, (cur.net_rx_bytes - prev.net_rx_bytes) / dt),
      tx: Math.max(0, (cur.net_tx_bytes - prev.net_tx_bytes) / dt)
    });
  }
  return out;
}

function drawCharts() {
  if (!HISTORY.length) {
    document.querySelectorAll('.chart-card').forEach(c => {
      const cv = c.querySelector('canvas');
      if (cv) cv.replaceWith(Object.assign(document.createElement('div'), { className: 'empty', textContent: 'No history yet.' }));
    });
    return;
  }
  categoryChart('chart-load', [
    { label: '1 min',  fn: d => d.load1, color: '#4ea1ff' },
    { label: '5 min',  fn: d => d.load5, color: '#3ad29f' },
  ]);
  categoryChart('chart-mem', [
    { label: 'used MiB', fn: d => d.mem_used_mib, color: '#4ea1ff', fill: true },
    { label: 'swap MiB', fn: d => d.swap_used_mib, color: '#f5b94a' },
  ]);
  categoryChart('chart-disk', [
    { label: 'root %', fn: d => d.disk_used_pct, color: '#ef5f6b', fill: true },
  ]);

  // network rate uses derived series; align labels to history[1..]
  const ctx = document.getElementById('chart-net');
  if (chartInstances['chart-net']) chartInstances['chart-net'].destroy();
  const h = filteredHistory();
  const rates = netRateSeries();
  const labels = h.slice(1).map(d => {
    const dt = new Date(d.ts);
    return `${(dt.getMonth()+1).toString().padStart(2,'0')}-${dt.getDate().toString().padStart(2,'0')} ${dt.getHours().toString().padStart(2,'0')}:00`;
  });
  chartInstances['chart-net'] = new Chart(ctx, {
    type: 'line',
    data: {
      labels,
      datasets: [
        { label: 'rx B/s', data: rates.map(r => r.rx), borderColor: '#3ad29f', backgroundColor: '#3ad29f33', borderWidth: 2, pointRadius: 0, tension: 0.25 },
        { label: 'tx B/s', data: rates.map(r => r.tx), borderColor: '#4ea1ff', backgroundColor: '#4ea1ff33', borderWidth: 2, pointRadius: 0, tension: 0.25 },
      ]
    },
    options: { animation: false, responsive: true, maintainAspectRatio: false,
      plugins: { legend: { labels: { color: '#8a96a6' } } },
      scales: { x: { ticks: { color: '#8a96a6', maxTicksLimit: 8, autoSkip: true }, grid: { color: '#2c3645' } },
                y: { ticks: { color: '#8a96a6' }, grid: { color: '#2c3645' }, beginAtZero: true } }
    }
  });

  categoryChart('chart-containers', [
    { label: 'running', fn: d => d.containers_running, color: '#3ad29f', fill: true },
    { label: 'total',   fn: d => d.containers_total,   color: '#8a96a6' },
  ]);
  categoryChart('chart-sites', [
    { label: 'OK',    fn: d => d.sites_ok,    color: '#3ad29f', fill: true },
    { label: 'total', fn: d => d.sites_total, color: '#8a96a6' },
  ]);
  categoryChart('chart-db', [
    { label: 'DB total bytes', fn: d => d.db_total_bytes, color: '#4ea1ff', fill: true },
  ]);
  categoryChart('chart-backup', [
    { label: 'Backup dir bytes', fn: d => d.backup_total_bytes, color: '#f5b94a', fill: true },
  ]);
}

load();
