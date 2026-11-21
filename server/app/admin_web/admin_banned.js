'use strict';
// "Taqiqlangan kanallar" page: Telegram sources the app hides from search and refuses to open
// (Oliy sud ro'yxati). An entry with a username is matched by it alone; one without is matched by its exact title.
/* global api, run, esc, openModal, closeModal, confirmBox, can, ERRORS */

Object.assign(ERRORS, { CHANNEL_NOT_FOUND: 'Kanal topilmadi' });

async function renderBanned(el) {
  const list = await api('/v1/admin/banned-channels');
  const support = can('support');
  const rows = list.items.map((c) => `<tr data-q="${esc(`${c.title} ${c.username} ${c.note}`.toLowerCase())}">
      <td><b>${esc(c.title || '—')}</b>${c.active ? '' : ' <span class="pill bad">O\'chiq</span>'}</td>
      <td class="mono">${c.username ? esc(`t.me/${c.username}`) : '<span class="muted">nomi bo\'yicha</span>'}</td>
      <td class="muted">${esc(c.note)}</td>
      <td>${support ? `<div class="toolbar"><button class="btn" data-bc="edit" data-id="${esc(c.id)}">Tahrirlash</button>
        <button class="btn bad" data-bc="delete" data-id="${esc(c.id)}">O'chirish</button></div>` : ''}</td></tr>`).join('');
  el.innerHTML = `
    <div class="toolbar"><input id="bc-q" type="search" placeholder="Nomi, username yoki izoh" class="narrow">
      <span class="muted">${list.total} ta</span>
      ${support ? '<button class="btn primary" id="bc-new" type="button">+ Kanal qo\'shish</button>' : ''}</div>
    ${list.items.length ? `<div class="table-wrap"><table><thead><tr><th>Nomi</th><th>Havola</th><th>Izoh</th><th></th></tr></thead>
      <tbody id="bc-list">${rows}</tbody></table></div>` : '<div class="empty">Ro\'yxat bo\'sh</div>'}
    <p class="muted">Ilova bu kanallarni qidiruvda ko'rsatmaydi va havolasi orqali ochmaydi. Username yoki havola berilsa,
      faqat u bo'yicha topiladi; berilmasa, kanal nomi to'liq mos kelganda yashiriladi.</p>`;
  el.querySelector('#bc-new')?.addEventListener('click', () => editBanned(null, el));
  el.querySelector('#bc-q').oninput = (e) => {
    const q = e.target.value.trim().toLowerCase();
    el.querySelectorAll('#bc-list tr').forEach((row) => { row.hidden = q && !row.dataset.q.includes(q); });
  };
  el.querySelectorAll('[data-bc]').forEach((b) => {
    b.onclick = () => bannedAction(b.dataset.bc, list.items.find((c) => c.id === b.dataset.id), el);
  });
}

async function bannedAction(act, channel, el) {
  if (act === 'edit') return editBanned(channel, el);
  if (!(await confirmBox(`"${channel.title || channel.username}" ni o'chirish`, "Kanal ro'yxatdan olib tashlanadi va ilovada yana chiqadi.", "O'chirish"))) return undefined;
  await run(() => api(`/v1/admin/banned-channels/${channel.id}`, { method: 'DELETE' }), "O'chirildi");
  return renderBanned(el);
}

function editBanned(c, el) {
  const body = openModal(c ? 'Kanalni tahrirlash' : "Kanal qo'shish", `
    <form class="stack" id="bc-form">
      <div class="form-grid">
        <div class="field"><label for="bc-title">Kanal nomi</label><input id="bc-title" maxlength="300" value="${esc(c?.title || '')}"></div>
        <div class="field"><label for="bc-user">Username yoki havola</label>
          <input id="bc-user" maxlength="300" placeholder="@kanal yoki t.me/kanal" value="${esc(c?.username || '')}"></div>
        <div class="field"><label for="bc-note">Izoh</label><input id="bc-note" maxlength="300" value="${esc(c?.note || '')}"></div>
      </div>
      <label class="chip"><input type="checkbox" id="bc-active" ${!c || c.active ? 'checked' : ''}> Ilovada yashirilsin</label>
      <small>Nomi yoki username'dan kamida bittasi kerak.</small>
      <div><button class="btn primary" type="submit">Saqlash</button></div>
    </form>`);
  body.querySelector('#bc-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      title: body.querySelector('#bc-title').value.trim(), username: body.querySelector('#bc-user').value.trim(),
      note: body.querySelector('#bc-note').value.trim(), active: body.querySelector('#bc-active').checked,
    };
    const save = () => (c ? api(`/v1/admin/banned-channels/${c.id}`, { method: 'PUT', body: payload })
      : api('/v1/admin/banned-channels', { method: 'POST', body: payload }));
    if (await run(save, 'Saqlandi')) { closeModal(); renderBanned(el); }
  };
}
