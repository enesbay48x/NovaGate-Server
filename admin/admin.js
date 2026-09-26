/* ==========================================================================
   NOVAGATE ADMIN PANEL - client
   --------------------------------------------------------------------------
   SECURITY MODEL (this is a VIEW, not a control plane)
   ------------------------------------------------------------------
   Every action here calls the server and the server decides whether it is
   allowed. The permission set used to hide menu items comes from
   GET /admin/session, which the server derives from the `accounts` table.
   Hiding a tab is therefore only a usability measure: if a user edited this
   file to call POST /admin/player/x/currency anyway, the request still needs a
   valid JWT whose account row holds the `economy.manage` permission. The
   client can never grant itself authority it does not have on the server.
   ========================================================================== */
'use strict';

// --------------------------------------------------------------------------
// API base resolution - no hard-coded localhost anywhere
// --------------------------------------------------------------------------
function resolveApiBase() {
  const params = new URLSearchParams(window.location.search);
  const fromQuery = params.get('api');
  if (fromQuery) return fromQuery.replace(/\/+$/, '');
  if (window.__NOVAGATE_API__) return String(window.__NOVAGATE_API__).replace(/\/+$/, '');
  return window.location.origin;
}

const API = resolveApiBase();
const TOKEN_KEY = 'novagate_admin_token';

// --------------------------------------------------------------------------
// State
// --------------------------------------------------------------------------
const state = {
  token: localStorage.getItem(TOKEN_KEY) || '',
  session: null,          // { username, role, permissions[] }
  permissions: new Set(),
  catalog: [],
  view: 'dashboard',
  cache: {},
};

function can(permission) {
  return state.permissions.has(permission);
}

// --------------------------------------------------------------------------
// HTTP
// --------------------------------------------------------------------------
async function api(path, options = {}) {
  const opts = Object.assign({ headers: {} }, options);
  opts.headers = Object.assign(
    { 'Content-Type': 'application/json' }, opts.headers);
  if (state.token) opts.headers['Authorization'] = 'Bearer ' + state.token;

  const response = await fetch(API + path, opts);
  const text = await response.text();
  let payload = null;
  try { payload = text ? JSON.parse(text) : null; } catch (_e) { payload = text; }

  if (response.status === 401) {
    // An expired or revoked token returns the panel to the login screen.
    logout();
    throw new Error('Session expired. Please sign in again.');
  }
  if (!response.ok) {
    const detail = payload && payload.detail;
    let message = 'HTTP ' + response.status;
    if (typeof detail === 'string') message = detail;
    else if (detail && typeof detail === 'object') {
      message = detail.reason || JSON.stringify(detail);
    } else if (payload && payload.message) message = payload.message;
    const error = new Error(message);
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

const get = (path) => api(path, { method: 'GET' });
const post = (path, body) => api(path, {
  method: 'POST', body: JSON.stringify(body || {}),
});
const put = (path, body) => api(path, {
  method: 'PUT', body: JSON.stringify(body || {}),
});
const del = (path) => api(path, { method: 'DELETE' });

// --------------------------------------------------------------------------
// UI helpers
// --------------------------------------------------------------------------
function toast(message, ok = true) {
  const el = document.getElementById('toast');
  el.textContent = message;
  el.className = ok ? 'ok' : 'err';
  clearTimeout(toast._timer);
  toast._timer = setTimeout(() => { el.className = ''; }, 4200);
}

function fmtNumber(value) {
  const n = Number(value || 0);
  return n.toLocaleString('en-US');
}

function fmtTime(seconds) {
  if (!seconds) return '-';
  return new Date(Number(seconds) * 1000).toLocaleString();
}

function fmtDate(seconds) {
  if (!seconds) return '-';
  return new Date(Number(seconds) * 1000).toLocaleDateString();
}

function escapeHtml(value) {
  return String(value === null || value === undefined ? '' : value)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function roleBadge(role) {
  const known = ['player', 'moderator', 'admin', 'superadmin'];
  const cls = known.indexOf(role) >= 0 ? role : 'player';
  return '<span class="badge ' + cls + '">' + escapeHtml(role || 'player') + '</span>';
}

/** Build a table from a column spec and rows. */
function table(columns, rows) {
  if (!rows || !rows.length) return '<div class="empty">No records.</div>';
  const head = columns.map((c) => '<th>' + c.title + '</th>').join('');
  const body = rows.map((row) => {
    const cells = columns.map((c) => {
      const raw = typeof c.get === 'function' ? c.get(row) : row[c.key];
      const cls = c.num ? ' class="num"' : '';
      return '<td' + cls + '>' + (c.html ? raw : escapeHtml(raw)) + '</td>';
    }).join('');
    return '<tr>' + cells + '</tr>';
  }).join('');
  return '<div class="tablewrap"><table><thead><tr>' + head +
    '</tr></thead><tbody>' + body + '</tbody></table></div>';
}

function card(key, value, tone) {
  return '<div class="card"><div class="k">' + escapeHtml(key) +
    '</div><div class="v ' + (tone || '') + '">' + escapeHtml(value) + '</div></div>';
}

// --------------------------------------------------------------------------
// VIEWS
// --------------------------------------------------------------------------
const views = {};

views.dashboard = async function (root) {
  const d = await get('/admin/dashboard');
  const sched = d.scheduler || {};
  root.innerHTML =
    '<div class="cards">' +
    card('Online Players', fmtNumber(d.online_players), 'ok') +
    card('Total Accounts', fmtNumber(d.total_accounts)) +
    card('BTC Economy', fmtNumber(d.btc_economy)) +
    card('PLT Economy', fmtNumber(d.plt_economy)) +
    card('GOLD Economy', fmtNumber(d.gold_economy)) +
    card('NPC Active', fmtNumber(d.npc_alive) + ' / ' + fmtNumber(d.npc_total)) +
    card('Active Maps', fmtNumber(d.active_maps)) +
    card('WebSocket Connections', fmtNumber(d.websocket_connections)) +
    card('Errors', fmtNumber(d.errors), d.errors ? 'bad' : 'ok') +
    '</div>' +
    '<div class="panel"><h3>Server status</h3><div class="cards">' +
    card('Scheduler', sched.running ? 'RUNNING' : 'STOPPED',
      sched.running ? 'ok' : 'warn') +
    card('Sweeps', fmtNumber(sched.sweeps)) +
    card('Maintenance', d.maintenance ? 'ON' : 'OFF', d.maintenance ? 'warn' : 'ok') +
    '</div>' +
    (sched.last_error
      ? '<div class="hint" style="color:var(--bad)">Last scheduler error: ' +
        escapeHtml(sched.last_error) + '</div>'
      : '<div class="hint">Auction settlement and the event scheduler run on ' +
        'a 5s loop and are rebuilt from the database on every boot.</div>') +
    '</div>';
};

views.players = async function (root) {
  const search = state.cache.playerSearch || '';
  const data = await get('/admin/players?limit=200&search=' +
    encodeURIComponent(search));
  root.innerHTML =
    '<div class="panel"><h3>Search</h3><div class="row">' +
    '<div class="field"><label>Username or Player ID</label>' +
    '<input type="search" id="pSearch" value="' + escapeHtml(search) +
    '"></div>' +
    '<button class="primary" onclick="searchPlayers()">Search</button>' +
    '<button onclick="loadView()">Reset</button>' +
    '</div><div class="hint">Server-side search. The panel filters nothing ' +
    'locally, so what you see is exactly what the server returned.</div></div>' +
    table([
      { title: 'Username', key: 'username' },
      { title: 'Player ID', key: 'player_id' },
      { title: 'Company', key: 'company' },
      { title: 'Role', html: (r) => roleBadge(r.role) },
      { title: 'Status', html: (r) => r.online
        ? '<span class="online">ONLINE</span>' : '<span class="offline">offline</span>' },
      { title: 'Level', key: 'level', num: true },
      { title: 'XP', key: 'xp', num: true },
      { title: 'Honor', key: 'honor', num: true },
      { title: 'HP', get: (r) => Math.round(r.hp), num: true },
      { title: 'Shield', get: (r) => Math.round(r.shield), num: true },
      { title: 'BTC', key: 'btc', num: true },
      { title: 'PLT', key: 'plt', num: true },
      { title: 'GOLD', key: 'gold', num: true },
      { title: 'Kills', get: (r) => (r.npc_kills + r.player_kills), num: true },
      { title: 'Deaths', key: 'deaths', num: true },
      { title: 'Map', key: 'map_id' },
      { title: 'Last Login', get: (r) => fmtDate(r.last_login) },
      { title: '', html: (r) => '<button onclick="openPlayer(\'' +
        escapeHtml(r.player_id) + '\')">Manage</button>' },
    ], data.players);
};

window.searchPlayers = function () {
  state.cache.playerSearch = document.getElementById('pSearch').value;
  return loadView();
};

window.openPlayer = async function (playerId) {
  try {
    state.cache.currentPlayer =
      await get('/admin/player/' + encodeURIComponent(playerId));
    state.view = 'player';
    location.hash = '#player/' + encodeURIComponent(playerId);
    return loadView();
  } catch (error) { toast(error.message, false); }
};

// --------------------------------------------------------------------------
// Player detail: identity, vitals and one form per authority the server granted
// --------------------------------------------------------------------------
views.player = async function (root) {
  const p = state.cache.currentPlayer;
  if (!p) return views.players(root);

  const ident = encodeURIComponent(p.player_id);
  root.innerHTML =
    '<div class="panel"><h3>Identity</h3><div class="cards">' +
    card('Username', p.username) +
    card('Player ID', p.player_id, 'small') +
    card('Role', p.role, 'small') +
    card('Company', p.company || '-', 'small') +
    card('Status', p.online ? 'ONLINE' : 'OFFLINE', p.online ? 'ok' : '') +
    card('Ship', p.ship_id, 'small') +
    card('Map', p.map_id, 'small') +
    '</div><div class="row" style="margin-top:14px">' +
    '<button onclick="state.view=\'players\';loadView()">Back to list</button>' +
    (can('player.kick')
      ? '<button class="danger" onclick="adminKick(\'' + ident +
        '\')">Kick</button>' : '') +
    (can('chat.moderate')
      ? '<button onclick="adminMute(\'' + ident + '\',' +
        (p.muted ? 'false' : 'true') + ')">' + (p.muted ? 'Unmute' : 'Mute') +
        '</button>' : '') +
    '</div></div>' +

    '<div class="panel"><h3>Vitals and progression</h3><div class="cards">' +
    card('Level', p.level) + card('XP', fmtNumber(p.xp)) +
    card('Honor', fmtNumber(p.honor)) +
    card('HP', Math.round(p.hp) + ' / ' + Math.round(p.max_hp), 'small') +
    card('Shield', Math.round(p.shield) + ' / ' + Math.round(p.max_shield), 'small') +
    card('NPC Kills', p.npc_kills, 'small') +
    card('Player Kills', p.player_kills, 'small') +
    card('Deaths', p.deaths, 'small') +
    '</div></div>' +

    (can('economy.manage') ? currencyForm(ident) : '') +
    (can('inventory.manage') ? itemForm(ident) : '') +
    (can('stats.manage') ? statsForm(ident) : '') +
    (can('equipment.manage') ? equipmentForm(ident, p) : '') +
    (can('ship.manage') ? shipForm(ident, p) : '') +
    (can('player.teleport') ? teleportForm(ident, p) : '') +
    (can('quest.manage') ? questForm(ident) : '') +
    (can('gate.manage') ? gateForm(ident) : '') +

    '<div class="panel"><h3>Server-side state</h3>' +
    table([
      { title: 'Type', key: 'type' },
      { title: 'Item', key: 'item' },
      { title: 'Value', key: 'value', num: true },
    ], flattenServerState(p)) + '</div>';
};

/** Flatten inventory / ammo / drones / gates into one comparable table. */
function flattenServerState(p) {
  const rows = [];
  Object.keys(p.inventory || {}).forEach((id) => rows.push({
    type: 'inventory', item: id, value: p.inventory[id],
  }));
  Object.keys(p.ammo || {}).forEach((id) => rows.push({
    type: 'ammo', item: id, value: p.ammo[id],
  }));
  (p.drones || []).forEach((d, i) => rows.push({
    type: 'drone', item: d.drone_type || ('slot ' + i),
    value: d.laser_slots || 0,
  }));
  (p.gates || []).forEach((g) => rows.push({
    type: 'gate', item: g.gate_id, value: g.state,
  }));
  return rows;
}

// --------------------------------------------------------------------------
// Action forms
// --------------------------------------------------------------------------
/** Every mutation goes through here: POST, then reload, then report. */
async function act(fn, successMessage) {
  try {
    await fn();
    toast(successMessage || 'Done.');
    if (state.view === 'player' && state.cache.currentPlayer) {
      state.cache.currentPlayer = await get('/admin/player/' +
        encodeURIComponent(state.cache.currentPlayer.player_id));
    }
    return loadView();
  } catch (error) { toast(error.message, false); }
}

const num = (id) => Number(document.getElementById(id).value || 0);
const txt = (id) => document.getElementById(id).value.trim();

function currencyForm(ident) {
  return '<div class="panel"><h3>Economy</h3><div class="row">' +
    '<div class="field"><label>Currency</label><select id="cur">' +
    '<option>BTC</option><option>PLT</option><option>GOLD</option>' +
    '</select></div>' +
    '<div class="field"><label>Amount (+/-)</label>' +
    '<input type="number" id="curAmt" value="1000"></div>' +
    '<div class="field"><label>Reason</label>' +
    '<input type="text" id="curWhy" placeholder="audit reason"></div>' +
    '<button class="primary" onclick="adminCurrency(\'' + ident +
    '\')">Apply</button></div>' +
    '<div class="hint">A negative amount removes currency and is refused if ' +
    'it would go below zero. Every change is written to the audit log with ' +
    'its old and new value.</div></div>';
}

window.adminCurrency = function (ident) {
  return act(() => post('/admin/player/' + ident + '/currency', {
    currency: txt('cur'), amount: num('curAmt'), reason: txt('curWhy'),
  }), 'Currency updated.');
};

function itemForm(ident) {
  const options = state.catalog.map((it) =>
    '<option value="' + escapeHtml(it[0]) + '">' + escapeHtml(it[1]) +
    ' (' + escapeHtml(it[0]) + ')</option>').join('');
  return '<div class="panel"><h3>Inventory</h3><div class="row">' +
    '<div class="field"><label>Item</label><select id="itId">' +
    options + '</select></div>' +
    '<div class="field"><label>Quantity (+/-)</label>' +
    '<input type="number" id="itQty" value="1"></div>' +
    '<div class="field"><label>Reason</label>' +
    '<input type="text" id="itWhy"></div>' +
    '<button class="primary" onclick="adminItem(\'' + ident +
    '\')">Apply</button></div>' +
    '<div class="hint">Canonical item ids come from the server catalog, so ' +
    'the panel can never offer an item the server would reject.</div></div>';
}

window.adminItem = function (ident) {
  return act(() => post('/admin/player/' + ident + '/item', {
    item_id: txt('itId'), quantity: num('itQty'), reason: txt('itWhy'),
  }), 'Inventory updated.');
};

function statsForm(ident) {
  return '<div class="panel"><h3>Stats and vitals</h3><div class="row">' +
    '<div class="field"><label>XP (absolute)</label>' +
    '<input type="number" id="stXp" value="0"></div>' +
    '<div class="field"><label>Honor (delta)</label>' +
    '<input type="number" id="stHonor" value="0"></div>' +
    '<div class="field"><label>Level (1-24)</label>' +
    '<input type="number" id="stLevel" value="1" min="1" max="24"></div>' +
    '<div class="field"><label>HP</label>' +
    '<input type="number" id="stHp" value="0"></div>' +
    '<div class="field"><label>Shield</label>' +
    '<input type="number" id="stShield" value="0"></div>' +
    '<div class="field"><label>Reason</label>' +
    '<input type="text" id="stWhy"></div>' +
    '<button class="primary" onclick="adminStats(\'' + ident +
    '\')">Apply</button></div>' +
    '<div class="hint">Level and XP are the same progression, so setting one ' +
    'recomputes the other from the level table. HP and shield are clamped to ' +
    'the player\'s own maxima by the server.</div></div>';
}

window.adminStats = function (ident) {
  return act(() => post('/admin/player/' + ident + '/stats', {
    xp: num('stXp') || null, honor: num('stHonor') || null,
    level: num('stLevel') || null, hp: num('stHp') || null,
    shield: num('stShield') || null, reason: txt('stWhy'),
  }), 'Stats updated.');
};

function equipmentForm(ident, p) {
  const loadout = (p.loadouts && (p.loadouts['1'] || p.loadouts[1])) || {};
  const lasers = (loadout.lasers || []).filter(Boolean);
  const gens = (loadout.generators || []).filter(Boolean);
  return '<div class="panel"><h3>Equipment and ammo</h3><div class="row">' +
    '<div class="field"><label>Ship</label><select id="eqShip">' +
    '<option>' + escapeHtml(p.ship_id) + '</option>' +
    '<option>Ship11</option><option>Ship12</option>' +
    '</select></div>' +
    '<div class="field"><label>Config</label><select id="eqCfg">' +
    '<option value="1">1</option><option value="2">2</option>' +
    '</select></div>' +
    '<div class="field"><label>Ammo ID</label>' +
    '<input type="text" id="eqAmmo" value="ammo_lf1"></div>' +
    '<div class="field"><label>Ammo qty (+/-)</label>' +
    '<input type="number" id="eqAmmoQty" value="50"></div>' +
    '<div class="field"><label>Reason</label>' +
    '<input type="text" id="eqWhy"></div>' +
    '</div><div class="row" style="margin-top:10px">' +
    '<div class="field"><label>Lasers (comma separated)</label>' +
    '<input type="text" id="eqLasers" value="' + escapeHtml(lasers.join(',')) +
    '"></div>' +
    '<div class="field"><label>Generators</label>' +
    '<input type="text" id="eqGens" value="' + escapeHtml(gens.join(',')) +
    '"></div>' +
    '<div class="field"><label>Extras</label>' +
    '<input type="text" id="eqExtras"></div>' +
    '<button class="primary" onclick="adminAmmo(\'' + ident +
    '\')">Set ammo</button>' +
    '<button onclick="adminLoadout(\'' + ident + '\')">Save loadout</button>' +
    '</div><div class="hint">Current config 1 - lasers: [' +
    escapeHtml(lasers.join(', ') || 'none') + '] generators: [' +
    escapeHtml(gens.join(', ') || 'none') + ']. A loadout save is validated ' +
    'against the player\'s own inventory on the server, so an admin cannot fit ' +
    'a laser the player does not own.</div></div>';
}

window.adminAmmo = function (ident) {
  return act(() => post('/admin/player/' + ident + '/ammo', {
    ammo_id: txt('eqAmmo'), quantity: num('eqAmmoQty'), reason: txt('eqWhy'),
  }), 'Ammo updated.');
};

window.adminLoadout = function (ident) {
  // The slot lists are comma-separated canonical ids; blanks are ignored.
  const parse = (value) => value.split(',').map((s) => s.trim())
    .filter((s) => s.length);
  return act(() => post('/admin/player/' + ident + '/loadout', {
    ship_id: txt('eqShip'), config_index: num('eqCfg'),
    lasers: parse(txt('eqLasers')), generators: parse(txt('eqGens')),
    extras: parse(txt('eqExtras')), selected: true, reason: txt('eqWhy'),
  }), 'Loadout saved.');
};

function shipForm(ident, p) {
  return '<div class="panel"><h3>Ship</h3><div class="row">' +
    '<div class="field"><label>Active ship</label><input type="text" ' +
    'id="shId" value="' + escapeHtml(p.ship_id) + '"></div>' +
    '<div class="field"><label>Reason</label><input type="text" id="shWhy">' +
    '</div><button class="primary" onclick="adminShip(\'' + ident +
    '\')">Change ship</button></div>' +
    '<div class="hint">Written to the session row and the live socket, so the ' +
    'world loop and the HUD agree immediately.</div></div>';
}

window.adminShip = function (ident) {
  return act(() => post('/admin/player/' + ident + '/ship', {
    ship_id: txt('shId'), reason: txt('shWhy'),
  }), 'Ship changed.');
};

function teleportForm(ident, p) {
  return '<div class="panel"><h3>Teleport</h3><div class="row">' +
    '<div class="field"><label>Map</label><input type="text" id="tpMap" ' +
    'value="' + escapeHtml(p.map_id || '1-1') + '"></div>' +
    '<div class="field"><label>X</label>' +
    '<input type="number" id="tpX" value="0"></div>' +
    '<div class="field"><label>Y</label>' +
    '<input type="number" id="tpY" value="0"></div>' +
    '<div class="field"><label>Reason</label><input type="text" id="tpWhy">' +
    '</div><button class="primary" onclick="adminTeleport(\'' + ident +
    '\')">Teleport</button></div>' +
    '<div class="hint">The server validates the map id against the world ' +
    'definition and persists the move, so it survives a reconnect.</div></div>';
}

window.adminTeleport = function (ident) {
  return act(() => post('/admin/player/' + ident + '/teleport', {
    map_id: txt('tpMap'), x: num('tpX'), y: num('tpY'), reason: txt('tpWhy'),
  }), 'Player teleported.');
};

window.adminKick = function (ident) {
  return act(() => post('/admin/player/' + ident + '/kick', {}), 'Player kicked.');
};

window.adminMute = function (ident, muted) {
  return act(() => post('/admin/player/' + ident + '/mute', {
    muted: muted === true || muted === 'true',
    reason: 'panel moderation action',
  }), muted ? 'Player muted.' : 'Player unmuted.');
};

// --------------------------------------------------------------------------
// Global views
// --------------------------------------------------------------------------
views.inventory = async function (root) {
  const data = await get('/admin/catalog');
  state.catalog = data.items || [];
  root.innerHTML = '<div class="panel"><h3>Item catalog (server-owned)</h3>' +
    '<div class="hint">The canonical ids below are what the server accepts. ' +
    'Use them in a player\'s Inventory form.</div><br><br>' +
    table([
      { title: 'Canonical ID', key: '0' },
      { title: 'Name', key: '1' },
      { title: 'Type', key: '2' },
      { title: 'Price', key: '3', num: true },
      { title: 'Currency', key: '4' },
      { title: 'Category', key: '5' },
    ], state.catalog) + '</div>';
};

views.equipment = async function (root) {
  const data = await get('/admin/players?limit=50');
  root.innerHTML =
    '<div class="panel"><h3>Equipment</h3><div class="hint">Equipment and ammo ' +
    'are edited per player. Open a player to reach the Equipment form, where ' +
    'the server validates every slot against that player\'s inventory.</div>' +
    '</div><div class="panel"><h3>Players</h3>' +
    table([
      { title: 'Username', key: 'username' },
      { title: 'Role', html: (r) => roleBadge(r.role) },
      { title: 'Status', html: (r) => r.online ? 'ONLINE' : 'offline' },
      { title: '', html: (r) => '<button onclick="openPlayer(\'' +
        escapeHtml(r.player_id) + '\')">Manage</button>' },
    ], data.players) + '</div>';
};

views.npc = async function (root) {
  const data = await get('/admin/npcs');
  root.innerHTML =
    '<div class="panel"><h3>Live NPCs</h3><div class="hint">NPC economy values ' +
    '(HP, damage, BTC/PLT rewards) are deliberately NOT editable here. Spawn ' +
    'and position controls cannot change the existing balance.</div></div>' +
    table([
      { title: 'NPC ID', key: 'npc_id' },
      { title: 'Type', key: 'npc_type' },
      { title: 'Map', key: 'map_id' },
      { title: 'HP', get: (r) => Math.round(r.hp || 0), num: true },
      { title: 'X', get: (r) => Math.round(r.x || 0), num: true },
      { title: 'Y', get: (r) => Math.round(r.y || 0), num: true },
      { title: 'State', get: (r) => (r.alive ? 'alive' : 'dead') },
      { title: '', html: (r) =>
        '<button onclick="npcAct(\'' + escapeHtml(r.npc_id) + '\',\'respawn\')">' +
        'Respawn</button> ' +
        '<button class="danger" onclick="npcAct(\'' + escapeHtml(r.npc_id) +
        '\',\'remove\')">Remove</button>' },
    ], data.npcs);
};

window.npcAct = function (npcId, action) {
  return act(() => action === 'remove'
    ? del('/admin/npcs/' + encodeURIComponent(npcId))
    : post('/admin/npcs/' + encodeURIComponent(npcId) + '/respawn', {}),
    'NPC ' + action + 'd.');
};

views.maps = async function (root) {
  const data = await get('/admin/maps');
  root.innerHTML =
    '<div class="panel"><h3>Maps</h3>' +
    table([
      { title: 'Map', key: 'map_id' },
      { title: 'Name', key: 'name' },
      { title: 'Min Level', key: 'min_level', num: true },
      { title: 'Company', key: 'company' },
      { title: 'Players', key: 'players', num: true },
      { title: 'NPCs', key: 'npcs', num: true },
    ], data.maps) + '</div>' +
    '<div class="panel"><h3>Portals</h3>' +
    table([
      { title: 'From', key: 'from_map' },
      { title: 'To', key: 'to_map' },
      { title: 'X', key: 'x', num: true },
      { title: 'Y', key: 'y', num: true },
      { title: 'Radius', key: 'radius', num: true },
    ], data.portals) + '</div>';
};

views.quests = async function (root) {
  const data = await get('/admin/quests');
  root.innerHTML =
    '<div class="panel"><h3>Quest definitions (server-owned)</h3>' +
    table([
      { title: 'Quest', key: 'quest_id' },
      { title: 'Title', key: 'title' },
      { title: 'Event', key: 'event' },
      { title: 'Target', key: 'target', num: true },
      { title: 'Min Level', key: 'min_level', num: true },
      { title: 'Reward', get: (r) => JSON.stringify(r.reward || {}) },
    ], data.definitions) + '</div>' +
    '<div class="panel"><h3>Active progress</h3>' +
    table([
      { title: 'Player ID', key: 'player_id' },
      { title: 'Quest', key: 'quest_id' },
      { title: 'State', key: 'state' },
      { title: 'Progress', key: 'progress', num: true },
      { title: 'Target', key: 'target', num: true },
    ], (data.players || []).flatMap((p) => p.quests.map((q) =>
      Object.assign({ player_id: p.player_id }, q)))) + '</div>' +
    '<div class="panel"><h3>Quest action</h3><div class="row">' +
    '<div class="field"><label>Player ID</label>' +
    '<input type="text" id="qaPid"></div>' +
    '<div class="field"><label>Quest</label><select id="qaQid">' +
    (data.definitions || []).map((d) => '<option>' + escapeHtml(d.quest_id) +
      '</option>').join('') + '</select></div>' +
    '<div class="field"><label>Action</label><select id="qaAct">' +
    '<option value="complete">Complete</option>' +
    '<option value="reset">Reset</option>' +
    '<option value="progress">Add progress</option></select></div>' +
    '<div class="field"><label>Amount</label>' +
    '<input type="number" id="qaAmt" value="1"></div>' +
    '<button class="primary" onclick="questAction()">Apply</button>' +
    '</div><div class="hint">Completing a quest pays the reward once: the ' +
    'server\'s unique reward key blocks a second payment even if an admin ' +
    'forces completion twice.</div></div>';
};

window.questAction = function () {
  const pid = encodeURIComponent(txt('qaPid'));
  return act(() => post('/admin/player/' + pid + '/quest', {
    quest_id: txt('qaQid'), action: txt('qaAct'),
    amount: num('qaAmt'), reason: 'panel quest action',
  }), 'Quest updated.');
};

views.gates = async function (root) {
  const data = await get('/admin/gates');
  const gates = (data.definitions || []).map((d) => d.gate_id);
  root.innerHTML =
    '<div class="panel"><h3>Gate definitions</h3>' +
    table([
      { title: 'Gate', key: 'gate_id' },
      { title: 'Parts', get: (r) => Object.entries(r.parts)
        .map(([pid, info]) => pid + ' x' + info.required +
          ' (L' + info.min_level + ')').join(', ') },
    ], data.definitions) + '</div>' +
    '<div class="panel"><h3>Completion reward</h3><div class="hint">' +
    escapeHtml(JSON.stringify(data.reward || {})) +
    '</div></div>' +
    '<div class="panel"><h3>Progress</h3>' +
    table([
      { title: 'Player ID', key: 'player_id' },
      { title: 'Gate', key: 'gate_id' },
      { title: 'State', key: 'state' },
      { title: 'Parts', get: (r) => JSON.stringify(r.parts || {}) },
      { title: 'Completed', get: (r) => fmtTime(r.completed_at) },
    ], data.progress) + '</div>' +
    '<div class="panel"><h3>Gate action</h3><div class="row">' +
    '<div class="field"><label>Player ID</label>' +
    '<input type="text" id="gaPid"></div>' +
    '<div class="field"><label>Gate</label><select id="gaGid">' +
    gates.map((g) => '<option>' + escapeHtml(g) + '</option>').join('') +
    '</select></div>' +
    '<div class="field"><label>Action</label><select id="gaAct">' +
    '<option value="reset">Reset</option>' +
    '<option value="complete">Force complete</option></select></div>' +
    '<button class="primary" onclick="gateAction()">Apply</button></div>' +
    '<div class="hint">Force completing repairs the gate state without paying ' +
    'the completion reward, so it cannot be used to hand out currency.</div>' +
    '</div>';
};

window.gateAction = function () {
  const pid = encodeURIComponent(txt('gaPid'));
  return act(() => post('/admin/player/' + pid + '/gate', {
    gate_id: txt('gaGid'), action: txt('gaAct'),
    reason: 'panel gate action',
  }), 'Gate updated.');
};

views.clans = async function (root) {
  const data = await get('/admin/clans');
  const canManage = can('clan.manage');
  root.innerHTML =
    '<div class="panel"><h3>Clans</h3>' +
    table([
      { title: 'Clan ID', key: 'clan_id' },
      { title: 'Name', key: 'name' },
      { title: 'Leader', key: 'leader' },
      { title: 'Members', key: 'member_count', num: true },
      { title: 'Created', get: (r) => fmtDate(r.created_at) },
      { title: '', html: (r) => (canManage
        ? '<button class="danger" onclick="disbandClan(\'' +
          escapeHtml(r.clan_id) + '\')">Disband</button>' : '') },
    ], data.clans) + '</div>' +
    '<div class="panel"><h3>Applications</h3>' +
    table([
      { title: 'ID', key: 'id', num: true },
      { title: 'Clan', key: 'clan_id' },
      { title: 'Player', key: 'player_id' },
      { title: 'Created', get: (r) => fmtDate(r.created_at) },
    ], data.applications) + '</div>' +
    (canManage ? '' : '<div class="hint">Removing a member or disbanding a ' +
      'clan requires a superadmin.</div>');
};

window.disbandClan = function (clanId) {
  if (!window.confirm('Disband ' + clanId + '? This cannot be undone.')) return;
  return act(() => post('/admin/clans/' + encodeURIComponent(clanId) +
    '/disband', { message: 'clan disbanded', reason: 'panel action' }),
    'Clan disbanded.');
};

views.squads = async function (root) {
  const data = await get('/admin/squads');
  const canManage = can('squad.manage');
  root.innerHTML = '<div class="panel"><h3>Squads</h3>' +
    table([
      { title: 'Squad ID', key: 'squad_id' },
      { title: 'Name', key: 'name' },
      { title: 'Leader', key: 'leader' },
      { title: 'Members', get: (r) => (r.members || []).length, num: true },
      { title: 'Created', get: (r) => fmtDate(r.created_at) },
      { title: '', html: (r) => (canManage
        ? '<button class="danger" onclick="dissolveSquad(\'' +
          escapeHtml(r.squad_id) + '\')">Dissolve</button>' : '') },
    ], data.squads) + '</div>';
};

window.dissolveSquad = function (squadId) {
  if (!window.confirm('Dissolve ' + squadId + '?')) return;
  return act(() => post('/admin/squads/' + encodeURIComponent(squadId) +
    '/dissolve', { message: 'squad dissolved', reason: 'panel action' }),
    'Squad dissolved.');
};

views.chat = async function (root) {
  const data = await get('/admin/chat/recent?limit=200');
  const mutes = can('chat.moderate') ? await get('/admin/mutes') : { mutes: [] };
  root.innerHTML =
    '<div class="panel"><h3>Online now</h3>' +
    '<div class="hint">' + (data.online || 0) + ' connected WebSocket(s).</div>' +
    '</div>' +
    '<div class="panel"><h3>Recent chat</h3>' +
    table([
      { title: 'Time', get: (r) => fmtTime(r.timestamp) },
      { title: 'From', key: 'from' },
      { title: 'Message', key: 'message' },
    ], data.messages) + '</div>' +
    (can('chat.moderate')
      ? '<div class="panel"><h3>Active mutes</h3>' +
        table([
          { title: 'Player', key: 'username' },
          { title: 'Reason', key: 'reason' },
          { title: 'By', key: 'muted_by' },
          { title: 'Expires', get: (r) => (r.until ? fmtTime(r.until) : 'never') },
          { title: '', html: (r) => '<button onclick="adminMute(\'' +
            escapeHtml(r.player_id) + '\',false)">Unmute</button>' },
        ], mutes.mutes) + '</div>'
      : '');
};

views.auctions = async function (root) {
  const filter = state.cache.auctionFilter || '';
  const data = await get('/admin/auctions' +
    (filter ? '?state=' + encodeURIComponent(filter) : ''));
  const canManage = can('auction.manage');
  const stateTone = { open: 'ok', settled: '', cancelled: 'bad' };
  root.innerHTML =
    '<div class="panel"><h3>Filter</h3><div class="row">' +
    '<div class="field"><label>State</label><select id="auState" onchange="' +
    'auctionFilter(this.value)"><option value="">All</option>' +
    '<option value="open"' + (filter === 'open' ? ' selected' : '') + '>Open</option>' +
    '<option value="settled"' + (filter === 'settled' ? ' selected' : '') + '>Settled</option>' +
    '<option value="cancelled"' + (filter === 'cancelled' ? ' selected' : '') +
    '>Cancelled</option></select></div></div>' +
    '<div class="hint">Expired open auctions are settled automatically by the ' +
    'background scheduler within about 5 seconds, with bidder refunds and a ' +
    'single-winner guard. Force settle calls the same code path.</div></div>' +
    table([
      { title: 'ID', key: 'auction_id', num: true },
      { title: 'Item', key: 'item_id' },
      { title: 'Qty', key: 'quantity', num: true },
      { title: 'Price', key: 'price', num: true },
      { title: 'Currency', key: 'currency' },
      { title: 'Seller', key: 'seller' },
      { title: 'Winner', get: (r) => r.highest_bidder || '-' },
      { title: 'State', html: (r) => '<span class="badge ' +
        (r.state === 'open' ? 'admin' : 'player') + '">' + escapeHtml(r.state) +
        '</span>' + (r.expired ? ' <span class="badge moderator">EXPIRED</span>' : '') },
      { title: 'Ends', get: (r) => fmtTime(r.ends_at) },
      { title: '', html: (r) => (canManage && r.state === 'open'
        ? '<button onclick="auctionAct(' + r.auction_id +
          ',\'settle\')">Settle</button> ' +
          '<button class="danger" onclick="auctionAct(' + r.auction_id +
          ',\'cancel\')">Cancel</button>' : '') },
    ], data.auctions);
};

window.auctionFilter = function (value) {
  state.cache.auctionFilter = value;
  return loadView();
};

window.auctionAct = function (auctionId, action) {
  return act(() => post('/admin/auctions/' + auctionId + '/' + action, {
    message: 'auction ' + action, reason: 'panel action',
  }), 'Auction ' + action + 'd.');
};

views.events = async function (root) {
  const data = await get('/admin/events');
  const canManage = can('event.manage');
  root.innerHTML =
    '<div class="panel"><h3>Events</h3><div class="hint">An event\'s state is ' +
    'derived from its start/end window on every read, so a restart can never ' +
    'leave one stuck active.</div></div>' +
    table([
      { title: 'Event ID', key: 'event_id' },
      { title: 'Name', key: 'name' },
      { title: 'Map', key: 'map_id' },
      { title: 'State', key: 'state' },
      { title: 'Starts', get: (r) => fmtTime(r.starts_at) },
      { title: 'Ends', get: (r) => fmtTime(r.ends_at) },
      { title: 'Reward', get: (r) => JSON.stringify(r.reward) },
      { title: '', html: (r) => (canManage
        ? '<button onclick="eventState(\'' + escapeHtml(r.event_id) +
          '\',true)">Start</button> ' +
          '<button onclick="eventState(\'' + escapeHtml(r.event_id) +
          '\',false)">Stop</button>' : '') },
    ], data.events) +
    (canManage
      ? '<div class="panel"><h3>Create or edit an event</h3><div class="row">' +
        '<div class="field"><label>Event ID</label>' +
        '<input type="text" id="evId"></div>' +
        '<div class="field"><label>Name</label>' +
        '<input type="text" id="evName"></div>' +
        '<div class="field"><label>Map</label>' +
        '<input type="text" id="evMap"></div>' +
        '<div class="field"><label>Starts (unix)</label>' +
        '<input type="number" id="evStart" value="0"></div>' +
        '<div class="field"><label>Ends (unix)</label>' +
        '<input type="number" id="evEnd" value="0"></div>' +
        '<div class="field"><label>BTC</label>' +
        '<input type="number" id="evBtc" value="0"></div>' +
        '<div class="field"><label>PLT</label>' +
        '<input type="number" id="evPlt" value="0"></div>' +
        '<div class="field"><label>XP</label>' +
        '<input type="number" id="evXp" value="0"></div>' +
        '<div class="field"><label>Honor</label>' +
        '<input type="number" id="evHonor" value="0"></div>' +
        '<button class="primary" onclick="eventSave()">Save event</button>' +
        '</div></div>'
      : '');
};

window.eventSave = function () {
  return act(() => post('/admin/events', {
    event_id: txt('evId'), name: txt('evName'), map_id: txt('evMap'),
    starts_at: num('evStart'), ends_at: num('evEnd'),
    reward_btc: num('evBtc'), reward_plt: num('evPlt'),
    reward_xp: num('evXp'), reward_honor: num('evHonor'),
    reason: 'panel event edit',
  }), 'Event saved.');
};

window.eventState = function (eventId, enabled) {
  return act(() => post('/admin/events/' + encodeURIComponent(eventId) +
    '/state', { enabled: enabled, reason: 'panel event control' }),
    enabled ? 'Event started.' : 'Event stopped.');
};

views.server = async function (root) {
  const d = await get('/admin/dashboard');
  const sched = d.scheduler || {};
  root.innerHTML =
    '<div class="cards">' +
    card('Online Players', fmtNumber(d.online_players), 'ok') +
    card('WebSockets', fmtNumber(d.websocket_connections)) +
    card('Active Maps', fmtNumber(d.active_maps)) +
    card('NPC Active', fmtNumber(d.npc_alive) + ' / ' + fmtNumber(d.npc_total)) +
    card('Scheduler Sweeps', fmtNumber(sched.sweeps)) +
    card('Errors', fmtNumber(d.errors), d.errors ? 'bad' : 'ok') +
    '</div>' +
    (can('server.control')
      ? '<div class="panel"><h3>Server controls (superadmin)</h3><div class="row">' +
        '<div class="field"><label>Maintenance</label><button ' +
        'onclick="serverFlag(\'maintenance\',' + (d.maintenance ? 'false' : 'true') +
        ')">' + (d.maintenance ? 'Disable maintenance' : 'Enable maintenance') +
        '</button></div>' +
        '<div class="field"><label>Broadcast</label>' +
        '<input type="text" id="bcMsg" placeholder="message to all players">' +
        '</div><button class="primary" onclick="serverBroadcast()">Send</button>' +
        '<div class="field"><label>Emergency</label><button class="danger" ' +
        'onclick="serverKickAll()">Kick all players</button></div>' +
        '</div><div class="hint">Maintenance is an in-memory flag that clears ' +
        'on restart, which is the safe direction to fail. A process restart or ' +
        'shutdown is deliberately NOT exposed here.</div></div>'
      : '<div class="hint">Server controls require a superadmin.</div>');
};

window.serverFlag = function (name, enabled) {
  return act(() => post('/admin/server/' + name, {
    enabled: enabled, reason: 'panel server control',
  }), 'Server flag updated.');
};

window.serverBroadcast = function () {
  return act(() => post('/admin/server/broadcast', {
    message: txt('bcMsg'), reason: 'panel broadcast',
  }), 'Broadcast sent.');
};

window.serverKickAll = function () {
  if (!window.confirm('Disconnect every player?')) return;
  return act(() => post('/admin/server/kick-all', {
    message: 'server restart', reason: 'panel emergency',
  }), 'All players disconnected.');
};

views.audit = async function (root) {
  const data = await get('/admin/audit?limit=300');
  root.innerHTML =
    '<div class="panel"><h3>Audit log</h3><div class="hint">Append-only. The ' +
    'database has triggers that ABORT any UPDATE or DELETE on this table, so ' +
    'no role - including superadmin - can edit or remove a record.</div></div>' +
    table([
      { title: 'When', get: (r) => fmtTime(r.timestamp) },
      { title: 'Admin', key: 'admin' },
      { title: 'Role', key: 'role' },
      { title: 'Action', key: 'action' },
      { title: 'Target', get: (r) => (r.target_type || '-') + ': ' + r.target },
      { title: 'Old', key: 'old_value' },
      { title: 'New', key: 'new_value' },
      { title: 'Reason', key: 'reason' },
      { title: 'IP', key: 'remote_addr' },
    ], data.entries);
};

views.admins = async function (root) {
  const data = await get('/admin/admins');
  root.innerHTML =
    '<div class="panel"><h3>Staff accounts</h3>' +
    table([
      { title: 'Username', key: 'username' },
      { title: 'Player ID', key: 'player_id' },
      { title: 'Role', html: (r) => roleBadge(r.role) },
      { title: 'Company', key: 'company' },
      { title: 'Last Login', get: (r) => fmtDate(r.last_login) },
    ], data.staff) + '</div>' +
    '<div class="panel"><h3>Assign a role</h3><div class="row">' +
    '<div class="field"><label>Username or Player ID</label>' +
    '<input type="text" id="rlTarget"></div>' +
    '<div class="field"><label>New role</label><select id="rlRole">' +
    (data.roles || []).map((r) => '<option value="' + escapeHtml(r.role) + '">' +
      escapeHtml(r.role) + '</option>').join('') +
    '</select></div>' +
    '<div class="field"><label>Reason</label>' +
    '<input type="text" id="rlWhy"></div>' +
    '<button class="primary" onclick="setRole()">Apply</button></div>' +
    '<div class="hint">The server enforces two rules regardless of what this ' +
    'form sends: you can only assign a role at or below your own, and you can ' +
    'never change your own role. So an admin cannot promote themselves.</div>' +
    '</div>' +
    '<div class="panel"><h3>Permission matrix</h3>' +
    table([
      { title: 'Role', key: 'role' },
      { title: 'Rank', key: 'rank', num: true },
      { title: 'Permissions', get: (r) => (r.permissions || []).join(', ') },
    ], data.roles) + '</div>';
};

window.setRole = function () {
  const target = encodeURIComponent(txt('rlTarget'));
  return act(() => put('/admin/player/' + target + '/role', {
    role: txt('rlRole'), reason: txt('rlWhy'),
  }), 'Role updated.');
};

views.settings = async function (root) {
  const data = await get('/admin/permissions');
  const s = state.session || {};
  root.innerHTML =
    '<div class="panel"><h3>This session</h3><div class="cards">' +
    card('Username', s.username || '-', 'small') +
    card('Role', s.role || '-', 'small') +
    card('Rank', String(s.rank === undefined ? '-' : s.rank), 'small') +
    '</div></div>' +
    '<div class="panel"><h3>Your permissions</h3><div class="hint">' +
    escapeHtml((s.permissions || []).join(', ') || 'none') + '</div></div>' +
    '<div class="panel"><h3>Connection</h3><div class="hint">API base: <code>' +
    escapeHtml(API) + '</code><br>Resolved at runtime from <code>?api=</code>, ' +
    '<code>window.__NOVAGATE_API__</code>, or this page\'s origin - so no ' +
    'environment URL is baked into the build.</div>' +
    '<div class="row" style="margin-top:12px">' +
    '<button onclick="logout()">Sign out</button></div></div>' +
    '<div class="panel"><h3>Full permission matrix</h3>' +
    table([
      { title: 'Role', key: 'role' },
      { title: 'Rank', key: 'rank', num: true },
      { title: 'Permissions', get: (r) => (r.permissions || []).join(', ') },
    ], data.matrix) + '</div>';
};

// --------------------------------------------------------------------------
// Menu
// --------------------------------------------------------------------------
// Each entry names the PERMISSION it needs. The server grants permissions, so
// an entry the account does not hold is hidden rather than shown-and-403.
const MENU = [
  { id: 'dashboard', label: 'Dashboard', perm: 'server.dashboard' },
  { id: 'players', label: 'Players', perm: 'player.lookup' },
  { id: 'inventory', label: 'Economy', perm: 'inventory.manage' },
  { id: 'equipment', label: 'Inventory', perm: 'equipment.manage' },
  { id: 'npc', label: 'NPC', perm: 'npc.manage' },
  { id: 'maps', label: 'Maps', perm: 'map.manage' },
  { id: 'quests', label: 'Quests', perm: 'quest.manage' },
  { id: 'gates', label: 'Gates', perm: 'gate.manage' },
  { id: 'clans', label: 'Clans', perm: 'clan.view' },
  { id: 'squads', label: 'Squads', perm: 'squad.view' },
  { id: 'chat', label: 'Chat', perm: 'chat.moderate' },
  { id: 'auctions', label: 'Auctions', perm: 'auction.view' },
  { id: 'events', label: 'Events', perm: 'event.view' },
  { id: 'server', label: 'Server', perm: 'server.dashboard' },
  { id: 'audit', label: 'Audit Log', perm: 'audit.view' },
  { id: 'admins', label: 'Admins', perm: 'role.manage' },
  { id: 'settings', label: 'Settings', perm: 'server.dashboard' },
];

function renderMenu() {
  const nav = document.getElementById('nav');
  nav.innerHTML = MENU.map((item) => {
    const allowed = can(item.perm);
    return '<a href="#' + item.id + '" data-view="' + item.id + '"' +
      (allowed ? '' : ' hidden') +
      (state.view === item.id ? ' class="active"' : '') + '>' +
      escapeHtml(item.label) + '</a>';
  }).join('');
  document.getElementById('who').innerHTML =
    'Signed in as <b>' + escapeHtml((state.session || {}).username || '') +
    '</b>' + escapeHtml((state.session || {}).role || '');
  const roleEl = document.getElementById('roleBadge');
  roleEl.textContent = (state.session || {}).role || '';
  roleEl.dataset.role = (state.session || {}).role || '';
}

window.navigate = function (view) {
  if (state.view === view) return;
  state.view = view;
  location.hash = '#' + view;
  return loadView();
};

async function loadView() {
  if (!state.token) return;
  renderMenu();
  const root = document.getElementById('content');
  const title = document.getElementById('viewTitle');
  const entry = MENU.find((m) => m.id === state.view);
  title.textContent = entry ? entry.label : state.view;
  root.innerHTML = '<div class="empty">Loading...</div>';
  try {
    if (state.view === 'player' && !state.cache.currentPlayer) {
      state.view = 'players';
      title.textContent = 'Players';
      await views.players(root);
    } else {
      const view = views[state.view] || views.dashboard;
      await view(root);
    }
  } catch (error) {
    root.innerHTML = '<div class="panel"><h3>Error</h3><div class="hint" ' +
      'style="color:var(--bad)">' + escapeHtml(error.message) + '</div></div>';
  }
}

window.loadView = loadView;

// --------------------------------------------------------------------------
// Auth + boot
// --------------------------------------------------------------------------
window.logout = function () {
  state.token = '';
  state.session = null;
  state.permissions = new Set();
  localStorage.removeItem(TOKEN_KEY);
  document.getElementById('app').className = '';
  document.getElementById('login').classList.remove('hidden');
};

/**
 * Sign in with a normal player credential.
 *
 * The panel does NOT ask for a role or an admin flag: it logs in as a player
 * and then asks the server what that account is actually allowed to do. A
 * player account simply comes back with an empty permission set.
 */
async function signIn(username, password) {
  const response = await fetch(API + '/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: username, password: password }),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload || !payload.access_token) {
    const detail = payload && payload.detail;
    throw new Error(typeof detail === 'string' ? detail : 'Login failed.');
  }
  state.token = payload.access_token;
  localStorage.setItem(TOKEN_KEY, state.token);
  // The server decides the role; the client never asserts one.
  const session = await get('/admin/session');
  state.session = session;
  state.permissions = new Set(session.permissions || []);
  document.getElementById('login').classList.add('hidden');
  document.getElementById('app').className = 'ready';
  state.view = 'dashboard';
  await loadView();
}

document.getElementById('loginForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const errorEl = document.getElementById('loginError');
  errorEl.textContent = '';
  try {
    await signIn(document.getElementById('username').value.trim(),
      document.getElementById('password').value);
  } catch (error) { errorEl.textContent = error.message; }
});

document.getElementById('nav').addEventListener('click', (e) => {
  const link = e.target.closest('a[data-view]');
  if (!link) return;
  e.preventDefault();
  navigate(link.dataset.view);
});

window.addEventListener('hashchange', () => {
  if (!state.token) return;
  const hash = location.hash.replace(/^#/, '');
  const match = MENU.find((m) => m.id === hash);
  if (match) {
    state.view = match.id;
    loadView();
  } else if (hash.startsWith('player/')) {
    const id = hash.slice('player/'.length);
    state.cache.currentPlayer = null;
    openPlayer(decodeURIComponent(id));
  }
});

// Boot: a stored token is only reused after the server confirms it.
(async function boot() {
  if (!state.token) return;
  try {
    const session = await get('/admin/session');
    state.session = session;
    state.permissions = new Set(session.permissions || []);
    document.getElementById('login').classList.add('hidden');
    document.getElementById('app').className = 'ready';
    const hash = location.hash.replace(/^#/, '');
    const match = MENU.find((m) => m.id === hash);
    state.view = match ? match.id : 'dashboard';
    await loadView();
  } catch (_error) {
    logout();
  }
})();
