'use strict';
// UZARO web admin panel: vanilla JS over the /v1/admin API with the X-Admin-Key header.
// Every server value goes through esc() before it reaches innerHTML.

const ROLE_RANK = { viewer: 0, support: 1, finance: 2, owner: 3 };
const ROLE_LABEL = { viewer: "Kuzatuvchi", support: "Moderator", finance: "Moliya", owner: "Egasi" };
const AD_STATUS = {
  pending_review: ['Tekshiruvda', 'warn'], awaiting_payment: ["To'lov kutilmoqda", 'info'],
  approved: ['Tasdiqlangan', 'ok'], rejected: ['Rad etilgan', 'bad'],
};
const SHOP_STATUS = {
  pending: ['Tekshiruvda', 'warn'], awaiting_payment: ["To'lov kutilmoqda", 'info'], approved: ['Faol', 'ok'],
  rejected: ['Rad etilgan', 'bad'], closed: ['Yopilgan', 'bad'], close_requested: ['Yopish so\'ralgan', 'gold'],
};
const ERRORS = {
  ADMIN_KEY_INVALID: "Admin kaliti noto'g'ri", LOGIN_INVALID: "Login yoki parol noto'g'ri", LOGIN_TAKEN: 'Bu login band', ADMIN_KEY_REQUIRED: 'Admin kaliti kerak', ADMIN_ROLE_INSUFFICIENT: "Bu amal uchun huquqingiz yetmaydi",
  RATE_LIMITED: "Juda ko'p urinish. 15 daqiqadan keyin qayta urining.", RECEIPT_REQUIRED: "To'lov cheki yuklanmagan",
  AD_NOT_PENDING_REVIEW: 'Reklama tekshiruv holatida emas', SHOP_NOT_REVIEWABLE: "Bu do'konni hozir tekshirib bo'lmaydi",
  ADMIN_NAME_TAKEN: 'Bu nom band', HTTP_422: "Maydonlarni tekshiring", CANNOT_CHANGE_OWN_ACCESS: "O'zingizning huquqingizni o'chira olmaysiz", VALIDATION_FAILED: "Maydonlarni tekshiring",
};

// In-app browsers (Telegram, Android WebView) often have no sessionStorage: reading it throws, so the session
// simply isn't remembered there instead of breaking the whole panel.
const store = {
  get(k) { try { return window.sessionStorage.getItem(k); } catch (_) { return null; } },
  set(k, v) { try { window.sessionStorage.setItem(k, v); } catch (_) { /* not remembered */ } },
  remove(k) { try { window.sessionStorage.removeItem(k); } catch (_) { /* nothing stored */ } },
};
const state = { key: store.get('uzaroAdminKey') || '', me: null, summary: {} };
const $ = (sel) => document.querySelector(sel);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const som = (n) => `${Number(n || 0).toLocaleString('uz-UZ').replace(/,/g, ' ')} so'm`;
const date = (iso) => (iso ? new Date(iso).toLocaleString('uz-UZ', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—');
const can = (role) => state.me && ROLE_RANK[state.me.role] >= ROLE_RANK[role];
const pill = (map, key) => { const [label, tone] = map[key] || [key, 'info']; return `<span class="pill ${tone}">${esc(label)}</span>`; };
const person = (p) => (p ? `${esc(`${p.first_name} ${p.last_name}`.trim() || '—')}${p.username ? ` · @${esc(p.username)}` : ''}${p.phone ? ` · ${esc(p.phone)}` : ''}` : '<span class="muted">Profil ulashilmagan</span>');

class ApiError extends Error {
  constructor(code, status) { super(code); this.code = code; this.status = status; }
}

async function api(path, { method = 'GET', body, raw = false } = {}) {
  const res = await fetch(path, {
    method,
    headers: { 'X-Admin-Key': state.key, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) { logout(); throw new ApiError('ADMIN_KEY_INVALID', 401); }
  if (!res.ok) {
    let code = `HTTP_${res.status}`;
    try { const data = await res.json(); code = data?.error?.code || data?.detail?.code || data?.code || code; } catch (_) { /* not JSON */ }
    if (res.status === 429) code = 'RATE_LIMITED';
    throw new ApiError(code, res.status);
  }
  if (raw) return res;
  return res.status === 204 ? null : res.json();
}

function toast(text, bad = false) {
  const el = $('#toast');
  el.textContent = text;
  el.className = `toast${bad ? ' bad' : ''}`;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 3200);
}

const errorText = (e) => ERRORS[e.code] || `Xatolik: ${e.code || e.message}`;

async function run(action, success) {
  try { const result = await action(); if (success) toast(success); return result; } catch (e) { toast(errorText(e), true); return undefined; }
}

// ------------------------------------------------------------------ modal

function openModal(title, html) {
  $('#modal-title').textContent = title;
  $('#modal-body').innerHTML = html;
  $('#modal').hidden = false;
  $('#modal-body').querySelector('input, textarea, select, button')?.focus();
  return $('#modal-body');
}
function closeModal() {
  $('#modal').hidden = true;
  $('#modal-body').querySelectorAll('img[data-blob]').forEach((img) => URL.revokeObjectURL(img.src));
  $('#modal-body').innerHTML = '';
}

function askReason(title, placeholder) {
  return new Promise((resolve) => {
    const body = openModal(title, `
      <div class="field"><label for="reason">Sabab</label><textarea id="reason" minlength="3" maxlength="256" placeholder="${esc(placeholder)}"></textarea>
      <small>Foydalanuvchiga ko'rsatiladi. Kamida 3 belgi.</small></div>
      <div class="toolbar"><button class="btn bad" id="reason-ok" type="button">Tasdiqlash</button><button class="btn" id="reason-cancel" type="button">Bekor qilish</button></div>`);
    body.querySelector('#reason-ok').onclick = () => {
      const value = body.querySelector('#reason').value.trim();
      if (value.length < 3) { toast('Sabab kamida 3 belgi', true); return; }
      closeModal(); resolve(value);
    };
    body.querySelector('#reason-cancel').onclick = () => { closeModal(); resolve(null); };
  });
}

function confirmBox(title, text, okLabel = 'Ha') {
  return new Promise((resolve) => {
    const body = openModal(title, `<p>${esc(text)}</p><div class="toolbar"><button class="btn primary" id="c-ok" type="button">${esc(okLabel)}</button><button class="btn" id="c-no" type="button">Bekor qilish</button></div>`);
    body.querySelector('#c-ok').onclick = () => { closeModal(); resolve(true); };
    body.querySelector('#c-no').onclick = () => { closeModal(); resolve(false); };
  });
}

async function showReceipt(path) {
  const res = await run(() => api(path, { raw: true }));
  if (!res) return;
  const url = URL.createObjectURL(await res.blob());
  openModal("To'lov cheki", `<img class="receipt" data-blob src="${url}" alt="To'lov cheki">`);
}

function mediaHtml(type, url) {
  if (!url) return '<span class="muted">Media yo\'q</span>';
  if (type === 'video' && /\.mp4($|\?)/i.test(url)) return `<video src="${esc(url)}" muted controls preload="metadata"></video>`;
  if (type === 'video') return `<a href="${esc(url)}" target="_blank" rel="noopener">Videoni ochish ↗</a>`;
  return `<img src="${esc(url)}" alt="" loading="lazy">`;
}

// ------------------------------------------------------------------ pages

const PAGES = {
  dashboard: { title: 'Bosh sahifa', role: 'viewer', render: renderDashboard },
  ads: { title: 'Reklamalar', role: 'viewer', render: renderAds, count: 'ads_pending' },
  shops: { title: 'Biznes profillar', role: 'viewer', render: renderShops, count: 'shops_pending' },
  users: { title: 'Foydalanuvchilar', role: 'support', render: renderUsers },
  settings: { title: 'Sozlamalar', role: 'viewer', render: renderSettings },
  admins: { title: 'Adminlar', role: 'owner', render: renderAdmins },
  audit: { title: 'Audit jurnali', role: 'owner', render: renderAudit },
};

function renderNav() {
  const current = location.hash.slice(1).split('/')[0] || 'dashboard';
  $('#nav').innerHTML = Object.entries(PAGES).filter(([, p]) => can(p.role)).map(([id, p]) => {
    const n = p.count ? state.summary[p.count] || 0 : 0;
    return `<a href="#${id}" ${id === current ? 'aria-current="page"' : ''}>${esc(p.title)}${n ? `<span class="count">${n}</span>` : ''}</a>`;
  }).join('');
}

async function route() {
  const [id, arg] = location.hash.slice(1).split('/');
  const page = PAGES[id] && can(PAGES[id].role) ? PAGES[id] : PAGES.dashboard;
  $('#page-title').textContent = page.title;
  $('#top-actions').innerHTML = '';
  $('#side').classList.remove('open');
  state.summary = (await run(() => api('/v1/admin/review/summary'))) || state.summary;
  renderNav();
  $('#page').innerHTML = '<p class="muted">Yuklanmoqda…</p>';
  try { await page.render($('#page'), arg); } catch (e) { $('#page').innerHTML = `<div class="empty">${esc(errorText(e))}</div>`; }
}

// dashboard

function barChart(points, key, gold, format) {
  const w = 600; const h = 170; const pad = 22;
  const max = Math.max(1, ...points.map((p) => p[key]));
  const step = (w - pad) / points.length;
  const bars = points.map((p, i) => {
    const bh = ((h - pad - 8) * p[key]) / max;
    return `<rect class="bar${gold ? ' gold' : ''}" x="${pad + i * step + 1}" y="${h - pad - bh}" width="${Math.max(2, step - 3)}" height="${bh}" rx="2"><title>${esc(p.date)}: ${esc(format(p[key]))}</title></rect>`;
  }).join('');
  const labels = [0, Math.floor(points.length / 2), points.length - 1].map((i) =>
    `<text x="${pad + i * step}" y="${h - 6}">${esc(points[i].date.slice(5))}</text>`).join('');
  return `<svg viewBox="0 0 ${w} ${h}" role="img"><line class="grid" x1="${pad}" x2="${w}" y1="${h - pad}" y2="${h - pad}"/>
    <text x="0" y="12">${esc(format(max))}</text>${bars}${labels}</svg>`;
}

async function renderDashboard(el) {
  const s = await api('/v1/admin/stats');
  const sum = state.summary;
  const shopsActive = s.shops.approved || 0;
  el.innerHTML = `
    <div class="kpis">
      <div class="kpi"><span class="label">Foydalanuvchilar</span><span class="value">${s.users.total}</span><span class="sub">+${s.users.new_7d} oxirgi 7 kunda</span></div>
      <div class="kpi"><span class="label">Faol biznes profillar</span><span class="value">${shopsActive}</span><span class="sub">${s.products_active} ta mahsulot sotuvda</span></div>
      <div class="kpi"><span class="label">Hozir ko'rsatilayotgan reklama</span><span class="value">${s.ads_live}</span><span class="sub">${s.ads.approved || 0} ta tasdiqlangan jami</span></div>
      <div class="kpi money"><span class="label">Tushum (tasdiqlangan)</span><span class="value">${esc(som(s.revenue_uzs.total))}</span><span class="sub">Reklama ${esc(som(s.revenue_uzs.ads))} · Do'kon ${esc(som(s.revenue_uzs.shops))}</span></div>
    </div>
    <div class="queues">
      ${queue('#ads', 'Reklama tekshiruvi', sum.ads_pending)}
      ${queue('#shops', "Do'kon tekshiruvi", sum.shops_pending)}
      ${queue('#shops/close_requested', "Yopish so'rovlari", sum.shops_closing)}
      ${queue('#ads/awaiting_payment', "To'lov kutilayotgan reklama", s.ads.awaiting_payment || 0, true)}
    </div>
    <div class="charts">
      <div class="card chart"><h3>Yangi foydalanuvchilar — 30 kun</h3>${barChart(s.daily, 'new_users', false, (v) => `${v} ta`)}</div>
      <div class="card chart"><h3>Reklama tushumi — 30 kun</h3>${barChart(s.daily, 'ad_income_uzs', true, som)}</div>
    </div>`;
}

function queue(href, label, n, info = false) {
  return `<a class="queue${n ? '' : ' zero'}${info ? ' info' : ''}" href="${href}"><span>${esc(label)}</span><b>${n || 0}</b></a>`;
}

// ads

async function renderAds(el, status = 'pending_review') {
  const ads = await api(`/v1/admin/ads?status=${encodeURIComponent(status)}&limit=200`);
  const tabs = Object.entries(AD_STATUS).map(([k, [label]]) => `<button class="tab" data-status="${k}" aria-pressed="${k === status}">${esc(label)}</button>`).join('');
  el.innerHTML = `<div class="tabs">${tabs}</div>` + (ads.length ? `<div class="grid-cards">${ads.map(adCard).join('')}</div>` : '<div class="empty">Bu holatda reklama yo\'q</div>');
  el.querySelectorAll('.tab').forEach((b) => { b.onclick = () => { location.hash = `ads/${b.dataset.status}`; }; });
  el.querySelectorAll('[data-act]').forEach((b) => { b.onclick = () => adAction(b.dataset.act, b.dataset.id, status); });
}

function adCard(ad) {
  const support = can('support');
  return `<article class="item">
    <div class="media">${mediaHtml(ad.media_type, ad.media_url)}</div>
    <div class="body">
      <div class="toolbar">${pill(AD_STATUS, ad.status)}<span class="pill gold">${esc(som(ad.price_uzs))}</span></div>
      <h4>${esc(ad.title)}</h4>
      ${ad.text ? `<p class="text">${esc(ad.text)}</p>` : ''}
      <dl class="facts">
        <dt>Hududlar</dt><dd>${esc(ad.regions.join(', '))}</dd>
        <dt>Muddat</dt><dd>${ad.days} kun</dd>
        ${ad.link_url ? `<dt>Havola</dt><dd><a href="${esc(ad.link_url)}" target="_blank" rel="noopener">${esc(ad.link_url)}</a></dd>` : ''}
        <dt>Yuborilgan</dt><dd>${esc(date(ad.created_at))}</dd>
        ${ad.ends_at ? `<dt>Tugaydi</dt><dd>${esc(date(ad.ends_at))}</dd>` : ''}
        ${ad.reject_reason ? `<dt>Sabab</dt><dd>${esc(ad.reject_reason)}</dd>` : ''}
      </dl>
    </div>
    <div class="actions">
      ${ad.has_receipt && support ? `<button class="btn" data-act="receipt" data-id="${esc(ad.id)}">Chekni ko'rish</button>` : ''}
      ${ad.status === 'pending_review' && support ? `<button class="btn ok" data-act="approve" data-id="${esc(ad.id)}">Tasdiqlash</button><button class="btn bad" data-act="reject" data-id="${esc(ad.id)}">Rad etish</button>` : ''}
      ${ad.status === 'approved' && support ? `<button class="btn bad" data-act="stop" data-id="${esc(ad.id)}">To'xtatish</button>` : ''}
    </div>
  </article>`;
}

async function adAction(act, id, status) {
  if (act === 'receipt') return showReceipt(`/v1/admin/ads/${id}/receipt`);
  if (act === 'approve') {
    if (!(await confirmBox('Reklamani tasdiqlash', "To'lov tekshirildimi? Tasdiqlangach reklama darhol ko'rsatila boshlaydi.", 'Tasdiqlash'))) return undefined;
    await run(() => api(`/v1/admin/ads/${id}/approve`, { method: 'POST' }), 'Reklama tasdiqlandi');
  } else {
    const reason = await askReason(act === 'stop' ? "Reklamani to'xtatish" : 'Reklamani rad etish', 'Masalan: chek summasi mos emas');
    if (!reason) return undefined;
    await run(() => api(`/v1/admin/ads/${id}/reject`, { method: 'POST', body: { reason } }), act === 'stop' ? "Reklama to'xtatildi" : 'Reklama rad etildi');
  }
  location.hash = `ads/${status}`;
  return route();
}

// shops (business profiles)

async function renderShops(el, status = 'pending') {
  if (status.startsWith('id:')) return renderShopDetail(el, status.slice(3));
  const shops = await api(`/v1/admin/shops?status=${encodeURIComponent(status)}&limit=200`);
  const tabs = Object.entries(SHOP_STATUS).map(([k, [label]]) => `<button class="tab" data-status="${k}" aria-pressed="${k === status}">${esc(label)}</button>`).join('');
  const rows = shops.map((s) => `<tr class="clickable" data-id="${esc(s.id)}">
      <td>${s.logo_url ? `<img class="logo" src="${esc(s.logo_url)}" alt="">` : `<span class="logo">${esc((s.name || '?')[0])}</span>`}</td>
      <td><b>${esc(s.name)}</b><br><span class="muted">${esc(s.region)}</span></td>
      <td>${person(s.owner)}</td>
      <td class="num">${s.product_count ?? 0}</td>
      <td class="num">${s.price_uzs ? esc(som(s.price_uzs)) : '<span class="muted">Bepul</span>'}</td>
      <td>${pill(SHOP_STATUS, s.close_requested && s.status !== 'closed' ? 'close_requested' : s.status)}</td>
      <td class="muted">${esc(date(s.created_at))}</td></tr>`).join('');
  el.innerHTML = `<div class="tabs">${tabs}</div>` + (shops.length
    ? `<div class="table-wrap"><table><thead><tr><th></th><th>Do'kon</th><th>Egasi</th><th>Mahsulot</th><th>To'lov</th><th>Holat</th><th>Ochilgan</th></tr></thead><tbody>${rows}</tbody></table></div>`
    : '<div class="empty">Bu holatda do\'kon yo\'q</div>');
  el.querySelectorAll('.tab').forEach((b) => { b.onclick = () => { location.hash = `shops/${b.dataset.status}`; }; });
  el.querySelectorAll('tr[data-id]').forEach((tr) => { tr.onclick = () => { location.hash = `shops/id:${tr.dataset.id}`; }; });
  return undefined;
}

async function renderShopDetail(el, id) {
  const s = await api(`/v1/admin/shops/${encodeURIComponent(id)}`);
  const support = can('support');
  const statusKey = s.close_requested && s.status !== 'closed' ? 'close_requested' : s.status;
  $('#top-actions').innerHTML = '<a class="btn" href="#shops">← Ro\'yxatga</a>';
  el.innerHTML = `
    <div class="card">
      <div class="toolbar">${s.logo_url ? `<img class="logo" src="${esc(s.logo_url)}" alt="">` : `<span class="logo">${esc((s.name || '?')[0])}</span>`}
        <h3 class="flush">${esc(s.name)}</h3>${pill(SHOP_STATUS, statusKey)}${s.price_uzs ? `<span class="pill gold">${esc(som(s.price_uzs))}</span>` : ''}</div>
      <dl class="facts gap-top">
        <dt>Hudud</dt><dd>${esc(s.region)}</dd>
        <dt>Egasi</dt><dd>${person(s.owner)}</dd>
        <dt>Telefon</dt><dd>${esc(s.phone || '—')}</dd>
        <dt>Telegram</dt><dd>${s.telegram ? `@${esc(s.telegram)}` : '—'}</dd>
        <dt>Tavsif</dt><dd>${esc(s.description || '—')}</dd>
        <dt>Ochilgan</dt><dd>${esc(date(s.created_at))}</dd>
        ${s.reject_reason ? `<dt>Rad sababi</dt><dd>${esc(s.reject_reason)}</dd>` : ''}
        ${s.close_requested ? `<dt>Yopish sababi</dt><dd>${esc(s.close_reason || '—')}</dd>` : ''}
      </dl>
      ${support ? `<div class="toolbar gap-top">
        ${s.has_receipt ? '<button class="btn" data-act="receipt">Chekni ko\'rish</button>' : ''}
        ${['pending', 'rejected'].includes(s.status) ? '<button class="btn ok" data-act="approve">Tasdiqlash</button>' : ''}
        ${s.status !== 'closed' && s.status !== 'rejected' ? '<button class="btn bad" data-act="reject">Rad etish</button>' : ''}
        ${s.close_requested && s.status !== 'closed' ? '<button class="btn" data-act="keep">Yopishni rad etish</button>' : ''}
        ${s.status !== 'closed' ? '<button class="btn bad" data-act="close">Do\'konni yopish</button>' : ''}
      </div>` : ''}
    </div>
    <div class="card"><h3>Mahsulotlar (${s.products.length})</h3>
      ${s.products.length ? `<div class="products">${s.products.map((p) => `<div class="product${p.active ? '' : ' off'}">
        ${p.image_url ? `<img src="${esc(p.image_url)}" alt="" loading="lazy">` : `<div class="no-image">Rasm yo'q</div>`}
        <div class="p-body"><b>${esc(p.title)}</b><span class="num">${esc(som(p.price_uzs))}</span>
        <span class="muted">Qoldiq: ${p.stock} · ${p.active ? 'Sotuvda' : 'Yashirilgan'}</span>
        ${support ? `<button class="btn" data-product="${esc(p.id)}" data-active="${p.active}">${p.active ? 'Yashirish' : "Qayta ko'rsatish"}</button>` : ''}</div></div>`).join('')}</div>`
        : '<p class="muted">Hali mahsulot yo\'q</p>'}
    </div>`;
  el.querySelectorAll('[data-act]').forEach((b) => { b.onclick = () => shopAction(b.dataset.act, s.id); });
  el.querySelectorAll('[data-product]').forEach((b) => { b.onclick = () => productVisibility(b.dataset.product, b.dataset.active !== 'true', s.id); });
}

async function shopAction(act, id) {
  const base = `/v1/admin/shops/${id}`;
  if (act === 'receipt') return showReceipt(`${base}/receipt`);
  if (act === 'approve') {
    if (!(await confirmBox("Do'konni tasdiqlash", "Do'kon va uning mahsulotlari ilovada hammaga ko'rinadi.", 'Tasdiqlash'))) return undefined;
    await run(() => api(`${base}/approve`, { method: 'POST' }), "Do'kon tasdiqlandi");
  } else if (act === 'reject') {
    const reason = await askReason("Do'konni rad etish", "Masalan: ma'lumotlar to'liq emas");
    if (!reason) return undefined;
    await run(() => api(`${base}/reject`, { method: 'POST', body: { reason } }), "Do'kon rad etildi");
  } else if (act === 'close') {
    if (!(await confirmBox("Do'konni yopish", "Do'kon butunlay yopiladi, mahsulotlari ilovadan yo'qoladi. Buni qaytarib bo'lmaydi.", 'Yopish'))) return undefined;
    await run(() => api(`${base}/close`, { method: 'POST' }), "Do'kon yopildi");
  } else if (act === 'keep') {
    await run(() => api(`${base}/keep`, { method: 'POST' }), "Yopish so'rovi rad etildi");
  }
  return route();
}

async function productVisibility(id, active, shopId) {
  const reason = await askReason(active ? "Mahsulotni qayta ko'rsatish" : 'Mahsulotni yashirish', active ? 'Masalan: kamchilik tuzatildi' : "Masalan: taqiqlangan mahsulot");
  if (!reason) return;
  await run(() => api(`/v1/admin/products/${id}/visibility`, { method: 'POST', body: { active, reason } }), active ? "Mahsulot qayta ko'rsatildi" : 'Mahsulot yashirildi');
  location.hash = `shops/id:${shopId}`;
  route();
}

// users

async function renderUsers(el, arg = '') {
  const [q, pageRaw] = decodeURIComponent(arg).split('|');
  const page = Number(pageRaw || 0);
  const limit = 50;
  const data = await api(`/v1/admin/users?q=${encodeURIComponent(q || '')}&offset=${page * limit}&limit=${limit}`);
  el.innerHTML = `
    <form class="toolbar" id="user-search"><input id="user-q" type="search" placeholder="Ism, @username yoki telefon" value="${esc(q || '')}"><button class="btn primary" type="submit">Qidirish</button>
      <span class="muted">Jami: ${data.total}</span></form>
    ${data.users.length ? `<div class="table-wrap"><table><thead><tr><th>Foydalanuvchi</th><th>Platforma</th><th>Do'kon</th><th>Reklama</th><th>Ro'yxatdan o'tgan</th></tr></thead><tbody>
      ${data.users.map((u) => `<tr class="clickable" data-id="${esc(u.id)}"><td>${person(u.profile)}</td><td>${esc(u.platform || '—')}</td><td class="num">${u.shops}</td><td class="num">${u.ads}</td><td class="muted">${esc(date(u.created_at))}</td></tr>`).join('')}
    </tbody></table></div>` : '<div class="empty">Foydalanuvchi topilmadi</div>'}
    <div class="pager">${page > 0 ? '<button class="btn" id="prev">← Oldingi</button>' : ''}<span class="muted">${page + 1}-sahifa</span>${(page + 1) * limit < data.total ? '<button class="btn" id="next">Keyingi →</button>' : ''}</div>`;
  el.querySelector('#user-search').onsubmit = (e) => { e.preventDefault(); location.hash = `users/${encodeURIComponent(`${$('#user-q').value.trim()}|0`)}`; };
  el.querySelector('#prev')?.addEventListener('click', () => { location.hash = `users/${encodeURIComponent(`${q || ''}|${page - 1}`)}`; });
  el.querySelector('#next')?.addEventListener('click', () => { location.hash = `users/${encodeURIComponent(`${q || ''}|${page + 1}`)}`; });
  el.querySelectorAll('tr[data-id]').forEach((tr) => { tr.onclick = () => customerDetail(tr.dataset.id); });
}

async function customerDetail(id) {
  const c = await run(() => api(`/v1/admin/customers/${id}`));
  if (!c) return;
  const body = openModal('Foydalanuvchi', `
    <dl class="facts"><dt>ID</dt><dd class="mono">${esc(c.customer_id)}</dd><dt>Tarif</dt><dd>${esc(c.tier)}</dd><dt>Hudud</dt><dd>${esc(c.region || '—')}</dd>
      <dt>Ro'yxatdan o'tgan</dt><dd>${esc(date(c.created_at))}</dd><dt>Kreditlar</dt><dd class="num">${c.credits.allowance} limit · ${c.credits.purchased} sotib olingan · ${c.credits.reserved} band</dd></dl>
    <h4>Imkoniyatlar</h4>
    ${c.entitlements.length ? `<ul>${c.entitlements.map((e) => `<li>${esc(e.entitlement)} · ${esc(e.source)} · ${esc(date(e.expires_at))} gacha</li>`).join('')}</ul>` : '<p class="muted">Pullik imkoniyat yo\'q</p>'}
    <h4>Obunalar</h4>
    ${c.subscriptions.length ? `<ul>${c.subscriptions.map((s) => `<li>${esc(s.product_id)} · ${esc(s.status)} · ${esc(date(s.expires_at))}</li>`).join('')}</ul>` : '<p class="muted">Obuna yo\'q</p>'}
    <form id="grant" class="card stack"><b>Imkoniyat berish</b>
      <div class="form-grid"><div class="field"><label for="g-ent">Imkoniyat</label><input id="g-ent" required placeholder="masalan: premium"></div>
      <div class="field"><label for="g-exp">Qachongacha</label><input id="g-exp" type="date" required></div></div>
      <div class="field"><label for="g-reason">Sabab</label><input id="g-reason" required minlength="5"></div>
      <button class="btn primary" type="submit">Berish</button></form>
    ${can('finance') ? `<form id="credits" class="card stack"><b>Kreditlarni o'zgartirish</b>
      <div class="form-grid"><div class="field"><label for="cr-amount">Miqdor (+/−)</label><input id="cr-amount" type="number" required></div>
      <div class="field"><label for="cr-ref">Hujjat raqami</label><input id="cr-ref" required pattern="[A-Za-z0-9._:-]+"></div></div>
      <div class="field"><label for="cr-reason">Sabab</label><input id="cr-reason" required minlength="5"></div>
      <button class="btn primary" type="submit">Saqlash</button></form>` : ''}`);
  body.querySelector('#grant').onsubmit = async (e) => {
    e.preventDefault();
    const expires = new Date(`${body.querySelector('#g-exp').value}T23:59:59`).toISOString();
    const ok = await run(() => api(`/v1/admin/customers/${id}/overrides`, { method: 'POST', body: { entitlement: body.querySelector('#g-ent').value.trim(), expires_at: expires, reason: body.querySelector('#g-reason').value.trim() } }), 'Imkoniyat berildi');
    if (ok) { closeModal(); customerDetail(id); }
  };
  body.querySelector('#credits')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const ok = await run(() => api(`/v1/admin/customers/${id}/credits`, { method: 'POST', body: { amount: Number(body.querySelector('#cr-amount').value), reference: body.querySelector('#cr-ref').value.trim(), reason: body.querySelector('#cr-reason').value.trim() } }), 'Kreditlar yangilandi');
    if (ok) { closeModal(); customerDetail(id); }
  });
}

// settings

async function renderSettings(el) {
  const s = await api('/v1/admin/settings');
  const release = await api('/v1/app/release');
  const owner = can('owner');
  const field = (id, label, value, type = 'text', hint = '') =>
    `<div class="field"><label for="${id}">${esc(label)}</label><input id="${id}" type="${type}" value="${esc(value)}" ${owner ? '' : 'disabled'}>${hint ? `<small>${esc(hint)}</small>` : ''}</div>`;
  el.innerHTML = `
    <form class="card stack" id="settings-form">
      <h3>Narxlar</h3>
      <div class="form-grid">
        ${field('ad_price_per_region_day_uzs', "Reklama: 1 hudud × 1 kun (so'm)", s.ad_price_per_region_day_uzs, 'number')}
        ${field('extra_shop_price_uzs', "Qo'shimcha do'kon narxi (so'm)", s.extra_shop_price_uzs, 'number')}
        ${field('shop_free_limit', "Bepul do'konlar soni", s.shop_free_limit, 'number')}
      </div>
      <h3>To'lov kartasi</h3>
      <div class="form-grid">
        ${field('ad_payment_card', 'Karta raqami', s.ad_payment_card, 'text', 'Reklama va do\'kon egalari shu kartaga pul o\'tkazadi')}
        ${field('ad_payment_card_holder', 'Karta egasi', s.ad_payment_card_holder)}
      </div>
      <h3>Ilova versiyasi</h3>
      <div class="form-grid">
        ${field('app_version', 'Versiya', s.app_version, 'text', 'Masalan: 1.1.0')}
        ${field('app_build', 'Build raqami', s.app_build, 'number')}
      </div>
      <div class="field"><label for="app_release_notes">Yangiliklar (har qator — alohida band)</label><textarea id="app_release_notes" ${owner ? '' : 'disabled'}>${esc(s.app_release_notes)}</textarea></div>
      <p class="muted">Yuklab olish sahifasi: <a href="/download" target="_blank" rel="noopener">${esc(location.origin)}/download</a> · APK ${release.available ? `joylangan (${(release.size_bytes / 1048576).toFixed(1)} MB)` : 'hali joylanmagan'}</p>
      ${owner ? '<div><button class="btn primary" type="submit">Saqlash</button></div>' : '<p class="muted">Sozlamalarni faqat egasi o\'zgartira oladi.</p>'}
    </form>`;
  el.querySelector('#settings-form').onsubmit = async (e) => {
    e.preventDefault();
    const body = {};
    ['ad_price_per_region_day_uzs', 'extra_shop_price_uzs', 'shop_free_limit', 'app_build'].forEach((k) => { body[k] = Number(el.querySelector(`#${k}`).value || 0); });
    ['ad_payment_card', 'ad_payment_card_holder', 'app_version', 'app_release_notes'].forEach((k) => { body[k] = el.querySelector(`#${k}`).value.trim(); });
    await run(() => api('/v1/admin/settings', { method: 'PUT', body }), 'Sozlamalar saqlandi');
  };
}

// admins

async function renderAdmins(el) {
  const admins = await api('/v1/admin/admins');
  const roleOptions = (selected) => Object.entries(ROLE_LABEL).map(([k, v]) => `<option value="${k}" ${k === selected ? 'selected' : ''}>${esc(v)}</option>`).join('');
  el.innerHTML = `
    <form class="card toolbar" id="new-admin"><b>Yangi admin</b><input id="na-name" required placeholder="Nomi (lotin harflari)" pattern="[A-Za-z0-9._-]+" class="narrow">
      <select id="na-role" class="narrow">${roleOptions('support')}</select><button class="btn primary" type="submit">Yaratish</button></form>
    <div class="table-wrap"><table><thead><tr><th>Nomi</th><th>Login</th><th>Rol</th><th>Holat</th><th>Yaratilgan</th><th></th></tr></thead><tbody>
      ${admins.map((a) => `<tr><td><b>${esc(a.name)}</b>${a.id === state.me.id ? ' <span class="pill info">Siz</span>' : ''}</td>
        <td>${a.login ? esc(a.login) : '<span class="muted">—</span>'}</td>
        <td><select data-role="${esc(a.id)}" ${a.name === state.me.name ? 'disabled' : ''}>${roleOptions(a.role)}</select></td>
        <td>${a.active ? '<span class="pill ok">Faol</span>' : '<span class="pill bad">O\'chirilgan</span>'}</td>
        <td class="muted">${esc(date(a.created_at))}</td>
        <td class="toolbar"><button class="btn" data-creds="${esc(a.id)}" data-login="${esc(a.login || '')}">Login/parol</button>
          ${a.name === state.me.name ? '' : `<button class="btn ${a.active ? 'bad' : ''}" data-toggle="${esc(a.id)}" data-active="${a.active}">${a.active ? "O'chirish" : 'Yoqish'}</button>`}</td></tr>`).join('')}
    </tbody></table></div>
    <p class="muted">Rollar: Kuzatuvchi — faqat ko'radi; Moderator — reklama va do'konlarni tekshiradi; Moliya — kreditlarni ham o'zgartiradi; Egasi — hammasi, adminlar va sozlamalar.</p>`;
  el.querySelector('#new-admin').onsubmit = async (e) => {
    e.preventDefault();
    const created = await run(() => api('/v1/admin/admins', { method: 'POST', body: { name: $('#na-name').value.trim(), role: $('#na-role').value } }));
    if (!created) return;
    const body = openModal('Admin yaratildi', `<p><b>${esc(created.name)}</b> uchun kalit. U faqat hozir ko'rsatiladi — nusxa olib, xavfsiz yo'l bilan bering.</p>
      <div class="keybox" id="new-key">${esc(created.key)}</div><button class="btn primary" id="copy-key" type="button">Nusxa olish</button>`);
    body.querySelector('#copy-key').onclick = async () => {
      try { await navigator.clipboard.writeText(created.key); toast('Nusxa olindi'); } catch (_) { getSelection().selectAllChildren(body.querySelector('#new-key')); }
    };
    renderAdmins(el);
  };
  el.querySelectorAll('[data-role]').forEach((s) => { s.onchange = () => run(() => api(`/v1/admin/admins/${s.dataset.role}`, { method: 'PATCH', body: { role: s.value } }), 'Rol o\'zgartirildi'); });
  el.querySelectorAll('[data-creds]').forEach((b) => {
    b.onclick = () => {
      const body = openModal('Panelga kirish uchun login va parol', `
        <div class="field"><label for="cr-login">Login</label><input id="cr-login" value="${esc(b.dataset.login)}" pattern="[A-Za-z0-9._@+-]+" minlength="3"></div>
        <div class="field"><label for="cr-pass">Yangi parol</label><input id="cr-pass" type="password" minlength="6"><small>Kamida 6 belgi. Uzun va tasodifiy parol xavfsizroq.</small></div>
        <button class="btn primary" id="cr-save" type="button">Saqlash</button>`);
      body.querySelector('#cr-save').onclick = async () => {
        const ok = await run(() => api(`/v1/admin/admins/${b.dataset.creds}/credentials`, { method: 'PUT', body: { login: body.querySelector('#cr-login').value.trim(), password: body.querySelector('#cr-pass').value } }), 'Login va parol saqlandi');
        if (ok) { closeModal(); renderAdmins(el); }
      };
    };
  });
  el.querySelectorAll('[data-toggle]').forEach((b) => {
    b.onclick = async () => {
      const active = b.dataset.active !== 'true';
      if (!active && !(await confirmBox("Adminni o'chirish", 'Bu admin kaliti bilan endi kira olmaydi.', "O'chirish"))) return;
      await run(() => api(`/v1/admin/admins/${b.dataset.toggle}`, { method: 'PATCH', body: { active } }), active ? 'Admin yoqildi' : "Admin o'chirildi");
      renderAdmins(el);
    };
  });
}

// audit

const ACTION_LABEL = {
  ad_approved: 'Reklama tasdiqlandi', ad_rejected: 'Reklama rad etildi', shop_approved: "Do'kon tasdiqlandi", shop_rejected: "Do'kon rad etildi",
  shop_closed: "Do'kon yopildi", shop_close_declined: "Yopish so'rovi rad etildi", shop_viewed: "Do'kon ko'rildi", users_listed: "Foydalanuvchilar ko'rildi",
  customer_viewed: "Foydalanuvchi ko'rildi", override_granted: 'Imkoniyat berildi', override_revoked: 'Imkoniyat olib qo\'yildi', credits_adjusted: "Kreditlar o'zgartirildi",
  settings_updated: "Sozlamalar o'zgartirildi", admin_login: 'Panelga kirdi', admin_credentials_set: 'Login/parol berildi', admin_created: 'Admin yaratildi', admin_updated: "Admin o'zgartirildi", product_hidden: 'Mahsulot yashirildi', product_shown: "Mahsulot qayta ko'rsatildi",
};

async function renderAudit(el) {
  const rows = await api('/v1/admin/audit?limit=500');
  el.innerHTML = rows.length ? `<div class="table-wrap"><table><thead><tr><th>Vaqt</th><th>Kim</th><th>Amal</th><th>Obyekt</th><th>Tafsilot</th></tr></thead><tbody>
    ${rows.map((r) => `<tr><td class="muted num">${esc(date(r.at))}</td><td>${esc(r.actor)}</td><td>${esc(ACTION_LABEL[r.action] || r.action)}</td>
      <td class="mono">${esc(r.target)}</td><td class="muted">${esc(Object.entries(r.details || {}).map(([k, v]) => `${k}: ${v}`).join(', '))}</td></tr>`).join('')}
  </tbody></table></div>` : '<div class="empty">Jurnal bo\'sh</div>';
}

// ------------------------------------------------------------------ session

async function login(key) {
  state.key = key;
  const me = await api('/v1/admin/me');
  const admins = me.role === 'owner' ? await api('/v1/admin/admins') : [];
  state.me = { ...me, id: admins.find((a) => a.name === me.name)?.id };
  store.set('uzaroAdminKey', key);
  $('#login').hidden = true;
  $('#app').hidden = false;
  $('#whoami').innerHTML = `<b>${esc(me.name)}</b>${esc(ROLE_LABEL[me.role] || me.role)}`;
  await route();
}

async function loginWithPassword(loginName, password) {
  const res = await fetch('/v1/admin/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ login: loginName, password }),
  });
  if (!res.ok) {
    let code = res.status === 429 ? 'RATE_LIMITED' : `HTTP_${res.status}`;
    try { code = (await res.json())?.detail?.code || code; } catch (_) { /* not JSON */ }
    throw new ApiError(res.status === 429 ? 'RATE_LIMITED' : code, res.status);
  }
  const { token } = await res.json();
  await login(token);
}

function logout() {
  // A session token dies on the server too; a permanent key is unaffected.
  if (state.key) fetch('/v1/admin/logout', { method: 'POST', headers: { 'X-Admin-Key': state.key } }).catch(() => {});
  state.key = '';
  state.me = null;
  store.remove('uzaroAdminKey');
  $('#app').hidden = true;
  $('#login').hidden = false;
  $('#admin-key').value = '';
  $('#admin-password').value = '';
}

document.addEventListener('DOMContentLoaded', () => {
  $('#login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = $('#login-error');
    err.hidden = true;
    try {
      if ($('#by-key').hidden) await loginWithPassword($('#admin-login').value.trim(), $('#admin-password').value);
      else await login($('#admin-key').value.trim());
    } catch (ex) { err.textContent = errorText(ex); err.hidden = false; }
  });
  $('#switch-mode').onclick = () => {
    const byKey = $('#by-key').hidden;
    $('#by-key').hidden = !byKey;
    $('#by-password').hidden = byKey;
    $('#switch-mode').textContent = byKey ? 'Login va parol bilan kirish' : 'Kalit bilan kirish';
  };
  $('#logout').onclick = logout;
  $('#menu').onclick = () => $('#side').classList.toggle('open');
  $('#modal-close').onclick = closeModal;
  $('#modal').addEventListener('click', (e) => { if (e.target.id === 'modal') closeModal(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !$('#modal').hidden) closeModal(); });
  window.addEventListener('hashchange', () => { if (state.me) route(); });
  if (state.key) login(state.key).catch(() => logout()); else logout();
});
