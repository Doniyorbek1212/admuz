'use strict';
// "Tezkor havolalar" page: sites and apps pinned to every user's hub "Tezkor" row (paid placement).
// Position 1 shows first; a link stays until its last paid day ("Muddati"), or forever when that is empty.
/* global api, run, esc, openModal, closeModal, confirmBox, can, ERRORS, fetchJson */

Object.assign(ERRORS, {
  QUICK_LINK_NOT_FOUND: 'Havola topilmadi', URL_INVALID: "Sayt manzili noto'g'ri (masalan: uzum.uz)",
  PACKAGE_INVALID: "Android paket nomi noto'g'ri (masalan: uz.uzum.app)", NOT_AN_IMAGE: "Logo PNG, JPG yoki WebP rasm bo'lishi kerak",
  TITLE_REQUIRED: 'Nomini yozing',
});

async function renderQuickLinks(el) {
  const list = await api('/v1/admin/quick-links');
  const support = can('support');
  const rows = list.items.map((l) => `<tr>
      <td class="num"><b>${l.position}</b></td>
      <td>${l.logo_url ? `<img class="ql-logo" src="${esc(l.logo_url)}" alt="" width="40" height="40">` : `<span class="ql-logo ql-letter">${esc(l.title.slice(0, 1).toUpperCase())}</span>`}</td>
      <td><b>${esc(l.title)}</b> ${l.live ? '<span class="pill">Ko\'rinmoqda</span>' : '<span class="pill bad">Ko\'rinmaydi</span>'}
        <br><a class="mono" href="${esc(l.url)}" target="_blank" rel="noopener">${esc(l.url)}</a>
        ${l.android_package ? `<br><span class="muted mono">${esc(l.android_package)}</span>` : ''}</td>
      <td>${l.until ? esc(l.until) : '<span class="muted">Muddatsiz</span>'}</td>
      <td class="muted">${esc(l.note)}</td>
      <td>${support ? `<div class="toolbar"><button class="btn" data-ql="edit" data-id="${esc(l.id)}">Tahrirlash</button>
        <button class="btn bad" data-ql="delete" data-id="${esc(l.id)}">O'chirish</button></div>` : ''}</td></tr>`).join('');
  el.innerHTML = `
    <div class="toolbar"><span class="muted">${list.total} ta</span>
      ${support ? '<button class="btn primary" id="ql-new" type="button">+ Havola qo\'shish</button>' : ''}</div>
    ${list.items.length ? `<div class="table-wrap"><table><thead><tr><th>O'rin</th><th></th><th>Havola</th><th>Muddati</th><th>Izoh</th><th></th></tr></thead>
      <tbody>${rows}</tbody></table></div>` : '<div class="empty">Hali havola yo\'q</div>'}
    <p class="muted">Bu havolalar barcha foydalanuvchilarning "Töplam → Tezkor" bo'limida, ularning o'z havolalaridan oldin, o'rin
      tartibida chiqadi. Foydalanuvchi ularni o'chira olmaydi. Android paket berilsa va ilova telefonda o'rnatilgan bo'lsa,
      sayt o'rniga ilova ochiladi. Muddat tugagach (shu kun ham kiradi) havola o'zi yashirinadi.</p>`;
  el.querySelector('#ql-new')?.addEventListener('click', () => quickLinkForm(null, el));
  el.querySelectorAll('[data-ql]').forEach((b) => {
    b.onclick = () => quickLinkAction(b.dataset.ql, list.items.find((l) => l.id === b.dataset.id), el);
  });
}

async function quickLinkAction(act, link, el) {
  if (act === 'edit') return quickLinkForm(link, el);
  if (!(await confirmBox(`"${link.title}" ni o'chirish`, 'Havola barcha foydalanuvchilarda yo\'qoladi.', "O'chirish"))) return undefined;
  await run(() => api(`/v1/admin/quick-links/${link.id}`, { method: 'DELETE' }), "O'chirildi");
  return renderQuickLinks(el);
}

function quickLinkForm(l, el) {
  const body = openModal(l ? 'Havolani tahrirlash' : "Tezkor havola qo'shish", `
    <form class="stack" id="ql-form">
      <div class="form-grid">
        <div class="field"><label for="ql-title">Nomi (ilovada ko'rinadi)</label><input id="ql-title" required maxlength="40" value="${esc(l?.title || '')}"></div>
        <div class="field"><label for="ql-url">Sayt manzili</label><input id="ql-url" required maxlength="500" placeholder="uzum.uz" value="${esc(l?.url || '')}"></div>
        <div class="field"><label for="ql-pkg">Android paket (ixtiyoriy)</label><input id="ql-pkg" maxlength="150" placeholder="uz.uzum.app" value="${esc(l?.android_package || '')}">
          <span class="muted">Play Market havolasidagi <code>id=</code> dan keyingi qism.</span></div>
        <div class="field"><label for="ql-pos">O'rin (1 — birinchi)</label><input id="ql-pos" type="number" min="1" max="99" required value="${l?.position ?? 1}"></div>
        <div class="field"><label for="ql-until">Muddati (shu kungacha, ixtiyoriy)</label><input id="ql-until" type="date" value="${esc(l?.until || '')}"></div>
        <div class="field"><label for="ql-note">Izoh (faqat adminlarga: kim to'lagan, summa)</label><input id="ql-note" maxlength="300" value="${esc(l?.note || '')}"></div>
        <div class="field"><label for="ql-logo">Logo (PNG/JPG/WebP, kvadrat)</label><input id="ql-logo" type="file" accept="image/png,image/jpeg,image/webp">
          ${l?.logo_url ? `<label class="chip"><input type="checkbox" id="ql-nologo"> Logoni olib tashlash</label>` : ''}</div>
      </div>
      <label class="chip"><input type="checkbox" id="ql-active" ${!l || l.active ? 'checked' : ''}> Ilovada ko'rinsin</label>
      <div><button class="btn primary" type="submit">Saqlash</button></div>
    </form>`);
  body.querySelector('#ql-form').onsubmit = async (e) => {
    e.preventDefault();
    const form = new FormData();
    form.append('title', body.querySelector('#ql-title').value.trim());
    form.append('url', body.querySelector('#ql-url').value.trim());
    form.append('android_package', body.querySelector('#ql-pkg').value.trim());
    form.append('position', body.querySelector('#ql-pos').value || '1');
    form.append('active', body.querySelector('#ql-active').checked ? 'true' : 'false');
    form.append('note', body.querySelector('#ql-note').value.trim());
    const until = body.querySelector('#ql-until').value;
    if (until) form.append('until', until);
    const logo = body.querySelector('#ql-logo').files[0];
    if (logo) form.append('logo', logo);
    if (body.querySelector('#ql-nologo')?.checked) form.append('remove_logo', 'true');
    const save = () => fetchJson(l ? `/v1/admin/quick-links/${l.id}` : '/v1/admin/quick-links', { method: l ? 'PUT' : 'POST', body: form });
    if (await run(save, 'Saqlandi')) { closeModal(); renderQuickLinks(el); }
  };
}
