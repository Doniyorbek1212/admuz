'use strict';
// "O'yinlar" page: online chess/checkers arena tournaments. UZARO funds the prize pool; the admin sets how many
// places are paid and the split. After a tournament ends, Finance presses "Sovrinlarni to'lash" once and each
// placed player's prize lands on their UZARO balance (paying twice is refused by the server).
/* global api, run, esc, som, date, openModal, closeModal, confirmBox, can, ERRORS, pill, toast */

Object.assign(ERRORS, {
  TOURNAMENT_NOT_FOUND: 'Musobaqa topilmadi', TOURNAMENT_STARTED: "Boshlangan musobaqani tahrirlab bo'lmaydi",
  TOURNAMENT_OVER: 'Musobaqa allaqachon tugagan', TOURNAMENT_NOT_FINISHED: "Musobaqa hali tugamagan — sovrin keyin to'lanadi",
  TOURNAMENT_PAID: "Sovrinlar allaqachon to'langan", TOURNAMENT_IN_PAST: "Tugash vaqti o'tib ketgan",
  TIME_CONTROL_UNKNOWN: "Bunday vaqt nazorati yo'q", PLAYER_NOT_FOUND: "O'yinchi topilmadi",
});

const T_STATUS = {
  scheduled: ['Rejada', 'info'], running: ['Davom etmoqda', 'ok'], finished: ["Tugadi — to'lov kutilmoqda", 'warn'],
  paid: ["Sovrinlar to'langan", 'ok'], cancelled: ['Bekor qilingan', 'bad'],
};
const KIND = { chess: 'Shaxmat', checkers: 'Shashka' };
const SPEED = { bullet: 'Bullet', blitz: 'Blits', rapid: 'Rapid' };

async function renderGames(el, arg) {
  if (arg) return renderTournament(el, arg);
  const list = await api('/v1/admin/games/tournaments');
  const support = can('support');
  const rows = list.items.map((t) => `<tr>
      <td><a href="#games/${esc(t.id)}"><b>${esc(t.title)}</b></a><br><span class="muted">${esc(KIND[t.kind])} · ${t.initial / 60}+${t.increment} ${esc(SPEED[t.speed])}</span></td>
      <td>${esc(date(t.starts_at))}<br><span class="muted">${esc(date(t.ends_at))} gacha</span></td>
      <td class="num">${t.prize_uzs ? som(t.prize_uzs) : '<span class="muted">Sovrinsiz</span>'}
        ${t.prize_split.length ? `<br><span class="muted">${t.prize_split.map((p, i) => `${i + 1}: ${p}%`).join(' · ')}</span>` : ''}</td>
      <td class="num">${t.players}</td>
      <td>${pill(T_STATUS, t.status)}</td>
      <td><div class="toolbar">
        <a class="btn" href="#games/${esc(t.id)}">Natijalar</a>
        ${support && t.status === 'scheduled' ? `<button class="btn" data-tg="edit" data-id="${esc(t.id)}">Tahrirlash</button>` : ''}
        ${support && (t.status === 'scheduled' || t.status === 'running') ? `<button class="btn bad" data-tg="cancel" data-id="${esc(t.id)}">Bekor qilish</button>` : ''}
        ${can('finance') && t.status === 'finished' ? `<button class="btn primary" data-tg="pay" data-id="${esc(t.id)}">Sovrinlarni to'lash</button>` : ''}
      </div></td></tr>`).join('');
  el.innerHTML = `
    <div class="kpis">
      <div class="kpi"><span class="label">Hozir o'ynalayotgan</span><span class="value">${list.stats.active_games}</span></div>
      <div class="kpi"><span class="label">So'nggi 24 soatda o'yinlar</span><span class="value">${list.stats.games_24h}</span></div>
      <div class="kpi"><span class="label">O'yinchilar</span><span class="value">${list.stats.players}</span></div>
    </div>
    <div class="toolbar"><span class="muted">${list.items.length} ta musobaqa</span>
      ${support ? '<button class="btn primary" id="tg-new" type="button">+ Musobaqa yaratish</button>' : ''}</div>
    ${list.items.length ? `<div class="table-wrap"><table><thead><tr><th>Musobaqa</th><th>Vaqti</th><th>Sovrin</th><th>Qatnashchi</th><th>Holat</th><th></th></tr></thead>
      <tbody>${rows}</tbody></table></div>` : '<div class="empty">Hali musobaqa yo\'q</div>'}
    <p class="muted">Arena: musobaqa davomida bo'sh o'yinchilar avtomatik juftlanadi. G'alaba 2 ochko, durang 1; ketma-ket 2 g'alabadan
      keyin natijalar ikki barobar. Vaqt tugagach, boshlangan o'yinlar tugashi bilan o'rinlar hisoblanadi. Sovrin faqat
      "eng kam o'yin" shartini bajarganlarga beriladi va ularning UZARO balansiga tushadi.</p>`;
  el.querySelector('#tg-new')?.addEventListener('click', () => tournamentForm(null, list.time_controls, el));
  el.querySelectorAll('[data-tg]').forEach((b) => {
    b.onclick = () => tournamentAction(b.dataset.tg, list.items.find((t) => t.id === b.dataset.id), list.time_controls, el);
  });
  return undefined;
}

async function tournamentAction(act, t, controls, el) {
  if (act === 'edit') return tournamentForm(t, controls, el);
  if (act === 'cancel') {
    if (!(await confirmBox(`"${t.title}" ni bekor qilish`, "Musobaqa ilovada yo'qoladi, sovrin to'lanmaydi.", 'Bekor qilish'))) return undefined;
    await run(() => api(`/v1/admin/games/tournaments/${t.id}/cancel`, { method: 'POST' }), 'Bekor qilindi');
  }
  if (act === 'pay') {
    const detail = await run(() => api(`/v1/admin/games/tournaments/${t.id}`));
    if (!detail) return undefined;
    const winners = detail.standings.filter((r) => r.prize_uzs > 0);
    const text = winners.length
      ? winners.map((r) => `${r.place}-o'rin: ${r.name} — ${som(r.prize_uzs)}`).join('\n')
      : "Sovrinli o'rin olgan o'yinchi yo'q (kam o'yin o'ynalgan).";
    if (!(await confirmBox(`Sovrinlarni to'lash: ${som(winners.reduce((a, r) => a + r.prize_uzs, 0))}`, text, "To'lash"))) return undefined;
    const paid = await run(() => api(`/v1/admin/games/tournaments/${t.id}/pay`, { method: 'POST' }));
    if (paid) toast(`${paid.paid} kishiga jami ${som(paid.total_uzs)} to'landi`);
  }
  return renderGames(el);
}

function localInput(iso) {
  const d = iso ? new Date(iso) : new Date(Date.now() + 3600_000);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function tournamentForm(t, controls, el) {
  const minutes = t ? Math.round((new Date(t.ends_at) - new Date(t.starts_at)) / 60000) : 60;
  const tcOptions = controls.map((c) => {
    const value = `${c.initial}+${c.increment}`;
    const selected = t ? t.initial === c.initial && t.increment === c.increment : value === '180+2';
    return `<option value="${value}" ${selected ? 'selected' : ''}>${c.initial / 60}+${c.increment} — ${esc(SPEED[c.speed])}</option>`;
  }).join('');
  const body = openModal(t ? 'Musobaqani tahrirlash' : 'Yangi musobaqa', `
    <form class="stack" id="tg-form">
      <div class="form-grid">
        <div class="field"><label for="tg-title">Nomi</label><input id="tg-title" required minlength="3" maxlength="80" value="${esc(t?.title || '')}" placeholder="Shanba blits arenasi"></div>
        <div class="field"><label for="tg-kind">O'yin</label><select id="tg-kind">
          <option value="chess" ${t?.kind !== 'checkers' ? 'selected' : ''}>Shaxmat</option>
          <option value="checkers" ${t?.kind === 'checkers' ? 'selected' : ''}>Shashka (rus qoidasi)</option></select></div>
        <div class="field"><label for="tg-tc">Vaqt nazorati (daqiqa + qo'shimcha soniya)</label><select id="tg-tc">${tcOptions}</select></div>
        <div class="field"><label for="tg-start">Boshlanish vaqti</label><input id="tg-start" type="datetime-local" required value="${localInput(t?.starts_at)}"></div>
        <div class="field"><label for="tg-dur">Davomiyligi (daqiqa, 10–1440)</label><input id="tg-dur" type="number" min="10" max="1440" required value="${minutes}"></div>
        <div class="field"><label for="tg-min">Sovrin uchun eng kam o'yin</label><input id="tg-min" type="number" min="1" max="50" required value="${t?.min_games ?? 3}"></div>
        <div class="field"><label for="tg-prize">Sovrin jamg'armasi (so'm)</label><input id="tg-prize" type="number" min="0" max="100000000" step="1000" value="${t?.prize_uzs ?? 0}"></div>
        <div class="field"><label for="tg-split">O'rinlar ulushi, % (vergul bilan)</label><input id="tg-split" value="${esc((t?.prize_split || [50, 30, 20]).join(', '))}" placeholder="50, 30, 20">
          <span class="muted" id="tg-split-preview"></span></div>
      </div>
      <div class="field"><label for="tg-desc">Tavsif (ixtiyoriy, ilovada ko'rinadi)</label><textarea id="tg-desc" maxlength="1000">${esc(t?.description || '')}</textarea></div>
      <div><button class="btn primary" type="submit">Saqlash</button></div>
    </form>`);
  // Commas, spaces or semicolons between the numbers; null when something is not a whole percent.
  const split = () => {
    const tokens = body.querySelector('#tg-split').value.split(/[\s,;]+/).filter(Boolean);
    return tokens.every((v) => /^\d+$/.test(v) && Number(v) > 0) ? tokens.map(Number) : null;
  };
  const preview = () => {
    const prize = Number(body.querySelector('#tg-prize').value || 0);
    const parts = split();
    if (!parts) { body.querySelector('#tg-split-preview').textContent = "Faqat butun foizlar, masalan: 50, 30, 20"; return; }
    const sum = parts.reduce((a, b) => a + b, 0);
    body.querySelector('#tg-split-preview').textContent = sum > 100
      ? `Jami ${sum}% — 100% dan oshmasin`
      : parts.map((p, i) => `${i + 1}-o'rin: ${som(Math.floor((prize * p) / 100))}`).join(' · ') + (sum < 100 && parts.length ? ` (qolgan ${100 - sum}% to'lanmaydi)` : '');
  };
  body.querySelector('#tg-split').oninput = preview;
  body.querySelector('#tg-prize').oninput = preview;
  preview();
  body.querySelector('#tg-form').onsubmit = async (e) => {
    e.preventDefault();
    const [initial, increment] = body.querySelector('#tg-tc').value.split('+').map(Number);
    const start = new Date(body.querySelector('#tg-start').value);
    if (Number.isNaN(start.getTime())) { toast("Boshlanish vaqtini kiriting", true); return; }
    const parts = split();
    if (!parts) { toast("Ulushlarni butun foizlarda yozing, masalan: 50, 30, 20", true); return; }
    const payload = {
      kind: body.querySelector('#tg-kind').value,
      title: body.querySelector('#tg-title').value.trim(),
      description: body.querySelector('#tg-desc').value.trim(),
      initial, increment,
      starts_at: start.toISOString(),
      duration_minutes: Number(body.querySelector('#tg-dur').value),
      prize_uzs: Number(body.querySelector('#tg-prize').value || 0),
      prize_split: parts,
      min_games: Number(body.querySelector('#tg-min').value),
    };
    const sum = parts.reduce((a, b) => a + b, 0);
    if (sum > 100) { toast("Ulushlar jami 100% dan oshmasin", true); return; }
    if (payload.prize_uzs > 0 && !parts.length) { toast("Sovrin uchun o'rinlar ulushini yozing", true); return; }
    if (payload.prize_uzs > 0 && sum < 100
      && !(await confirmBox('Ulushlar 100% emas', `Jami ${sum}%: qolgan ${100 - sum}% hech kimga to'lanmaydi. Shunday saqlansinmi?`, 'Saqlash'))) return;
    const save = () => api(t ? `/v1/admin/games/tournaments/${t.id}` : '/v1/admin/games/tournaments', { method: t ? 'PUT' : 'POST', body: payload });
    if (await run(save, 'Saqlandi')) { closeModal(); renderGames(el); }
  };
}

async function renderTournament(el, id) {
  const t = await api(`/v1/admin/games/tournaments/${id}`);
  const support = can('support');
  const rows = t.standings.map((r) => `<tr class="${r.disqualified ? 'muted' : ''}">
      <td class="num"><b>${r.place ?? r.rank}</b></td>
      <td>${esc(r.name)} ${r.fire ? '🔥' : ''} ${r.disqualified ? '<span class="pill bad">Chetlatilgan</span>' : ''}
        ${r.telegram_user_id ? `<br><span class="muted mono">tg ${r.telegram_user_id}</span>` : ''}</td>
      <td class="num"><b>${r.score}</b></td><td class="num">${r.games}</td><td class="num">${r.wins}</td><td class="num">${r.rating}</td>
      <td class="num">${r.prize_uzs ? som(r.prize_uzs) : ''}</td>
      <td>${support && t.status !== 'paid' ? `<div class="toolbar">
        <button class="btn ${r.disqualified ? '' : 'bad'}" data-dq="${esc(r.customer_id)}" data-on="${r.disqualified ? 'false' : 'true'}">${r.disqualified ? 'Qaytarish' : 'Chetlatish'}</button>
        <button class="btn" data-ban="${esc(r.customer_id)}" data-on="${r.banned ? 'false' : 'true'}">${r.banned ? "Reytingli o'yinlarni ochish" : "Reytingli o'yinlarni yopish"}</button></div>` : ''}</td></tr>`).join('');
  el.innerHTML = `
    <p><a href="#games">← Musobaqalar</a></p>
    <h2>${esc(t.title)} ${pill(T_STATUS, t.status)}</h2>
    <p class="muted">${esc(KIND[t.kind])} · ${t.initial / 60}+${t.increment} · ${esc(date(t.starts_at))} — ${esc(date(t.ends_at))} ·
      sovrin ${t.prize_uzs ? som(t.prize_uzs) : "yo'q"} ${t.prizes.length ? `(${t.prizes.map((p, i) => `${i + 1}: ${som(p)}`).join(', ')})` : ''} · eng kam ${t.min_games} o'yin</p>
    ${t.description ? `<p>${esc(t.description)}</p>` : ''}
    ${t.standings.length ? `<div class="table-wrap"><table><thead><tr><th>O'rin</th><th>O'yinchi</th><th>Ochko</th><th>O'yin</th><th>G'alaba</th><th>Reyting</th><th>Sovrin</th><th></th></tr></thead>
      <tbody>${rows}</tbody></table></div>` : '<div class="empty">Hali hech kim yozilmagan</div>'}`;
  el.querySelectorAll('[data-dq]').forEach((b) => {
    b.onclick = async () => {
      await run(() => api(`/v1/admin/games/tournaments/${id}/disqualify`, { method: 'POST', body: { customer_id: b.dataset.dq, disqualified: b.dataset.on === 'true' } }), 'Saqlandi');
      renderTournament(el, id);
    };
  });
  el.querySelectorAll('[data-ban]').forEach((b) => {
    b.onclick = async () => {
      const ban = b.dataset.on === 'true';
      if (ban && !(await confirmBox("Reytingli o'yinlarni yopish", "Halol o'yin buzilganda: bu o'yinchi reytingli o'yin va musobaqalarga kira olmaydi.", 'Yopish'))) return;
      await run(() => api(`/v1/admin/games/players/${b.dataset.ban}/ban`, { method: 'POST', body: { banned: ban } }), ban ? 'Yopildi' : 'Ochildi');
      renderTournament(el, id);
    };
  });
}
