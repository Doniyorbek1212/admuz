'use strict';
// "Sovg'alar" page: the UZARO gift catalog (animated WebP/GIF, price, order, hide) and balance top-ups, which
// customers pay by card transfer: check the receipt, approve to credit the balance or reject with a reason.
/* global api, run, esc, toast, openModal, closeModal, confirmBox, can, ERRORS, fetchJson, som, date, showReceipt */

Object.assign(ERRORS, {
  NOT_A_GIFT_ANIMATION: "Fayl animatsion WebP yoki GIF bo'lishi kerak", GIFT_NOT_FOUND: "Sovg'a topilmadi",
  GIFT_IN_USE: "Bu sovg'a allaqachon yuborilgan: o'chirib bo'lmaydi, faqat yashirish mumkin",
  TOPUP_NOT_FOUND: "To'lov topilmadi", TOPUP_NOT_PENDING: "Bu to'lov allaqachon ko'rib chiqilgan",
  TELEGRAM_NOT_LINKED: "Bu Telegram ID UZARO hisobiga bog'lanmagan: foydalanuvchi ilovada Sovg'alar bo'limida bog'lashi kerak",
});

const TOPUP_STATUS = { pending: 'Kutilmoqda', approved: 'Tasdiqlangan', rejected: 'Rad etilgan' };

async function renderGifts(el, arg) {
  if (['pending', 'approved', 'rejected'].includes(arg)) return renderTopups(el, arg);
  const [list, topups] = await Promise.all([api('/v1/admin/gifts'), api('/v1/admin/gifts/topups')]);
  const support = can('support');
  const cards = list.items.map((g) => `<div class="card gift-card">
      <img src="${esc(g.animation_url)}" alt="" width="96" height="96" loading="lazy">
      <b>${esc(g.title)}</b><span class="pill gold">${esc(som(g.price_uzs))}</span>${g.video_url ? '<span class="pill">🎬 Video</span>' : ''}
      <span class="muted">Yuborilgan: ${g.sent}${g.active ? '' : ' · <span class="pill bad">Yashirin</span>'}</span>
      ${support ? `<div class="toolbar"><button class="btn" data-g="edit" data-id="${esc(g.id)}">Tahrirlash</button>
        ${g.sent ? '' : `<button class="btn bad" data-g="delete" data-id="${esc(g.id)}">O'chirish</button>`}</div>` : ''}
    </div>`).join('');
  el.innerHTML = `
    <div class="tabs"><a class="tab" href="#gifts" aria-pressed="true">Katalog · ${list.items.length}</a>
      <a class="tab" href="#gifts/pending" aria-pressed="false">To'lovlar · ${topups.pending} kutilmoqda</a></div>
    <div class="toolbar">${support ? '<button class="btn primary" id="g-new" type="button">+ Sovg\'a qo\'shish</button>' : ''}
      ${can('finance') ? '<button class="btn" id="g-bonus" type="button">+ Balansga bonus (keshbek)</button>' : ''}</div>
    ${list.items.length ? `<div class="gift-grid">${cards}</div>` : '<div class="empty">Hali sovg\'a yo\'q. Serverda <code>python -m app.cli seed-gifts</code> boshlang\'ich to\'plamni qo\'shadi.</div>'}
    <p class="muted">Sovg'alar UZARO balansidan sotib olinadi va faqat UZARO foydalanuvchilariga ko'rinadi. Fayl: animatsion WebP yoki GIF, 2 MB gacha, kvadrat (256×256 tavsiya).</p>`;
  el.querySelector('#g-new')?.addEventListener('click', () => giftForm(null, el));
  el.querySelector('#g-bonus')?.addEventListener('click', bonusForm);
  el.querySelectorAll('[data-g]').forEach((b) => { b.onclick = () => giftAction(b.dataset.g, list.items.find((g) => g.id === b.dataset.id), el); });
  return undefined;
}

async function giftAction(act, gift, el) {
  if (act === 'edit') return giftForm(gift, el);
  if (!(await confirmBox(`"${gift.title}" ni o'chirish`, "Sovg'a katalogdan butunlay o'chiriladi.", "O'chirish"))) return undefined;
  await run(() => api(`/v1/admin/gifts/${gift.id}`, { method: 'DELETE' }), "O'chirildi");
  return renderGifts(el, '');
}

function giftForm(gift, el) {
  const body = openModal(gift ? "Sovg'ani tahrirlash" : "Yangi sovg'a", `
    <form class="stack" id="g-form">
      <div class="form-grid">
        <div class="field"><label for="g-title">Nomi</label><input id="g-title" required maxlength="64" value="${esc(gift?.title || '')}"></div>
        <div class="field"><label for="g-price">Narxi (so'm)</label><input id="g-price" type="number" min="0" max="10000000" step="500" required value="${gift?.price_uzs ?? 5000}"></div>
        <div class="field"><label for="g-sort">Tartib (kichigi oldin)</label><input id="g-sort" type="number" min="0" max="10000" value="${gift?.sort ?? 0}"></div>
      </div>
      ${gift ? `<label class="chip"><input type="checkbox" id="g-active" ${gift.active ? 'checked' : ''}> Ilovada sotuvda</label>`
    : `<div class="field"><label for="g-file">Animatsiya (WebP yoki GIF)</label><input id="g-file" type="file" accept=".webp,.gif,image/webp,image/gif" required></div>
       <div class="field"><label for="g-video">Premium video (MP4, ovozli, ixtiyoriy)</label><input id="g-video" type="file" accept=".mp4,video/mp4">
         <span class="muted">Bo'lsa, qabul qilgan odamning profili ochilganda butun ekranda o'ynaydi. 10 MB gacha, tik (9:16).</span></div>`}
      <div><button class="btn primary" type="submit">Saqlash</button></div>
    </form>`);
  body.querySelector('#g-form').onsubmit = async (e) => {
    e.preventDefault();
    const title = body.querySelector('#g-title').value.trim();
    const price = Number(body.querySelector('#g-price').value);
    const sort = Number(body.querySelector('#g-sort').value || 0);
    let ok;
    if (gift) {
      const payload = { title, price_uzs: price, sort, active: body.querySelector('#g-active').checked };
      ok = await run(() => api(`/v1/admin/gifts/${gift.id}`, { method: 'PUT', body: payload }), 'Saqlandi');
    } else {
      const form = new FormData();
      form.append('file', body.querySelector('#g-file').files[0]);
      form.append('title', title);
      form.append('price_uzs', String(price));
      form.append('sort', String(sort));
      const video = body.querySelector('#g-video').files[0];
      if (video) form.append('video', video);
      ok = await run(() => fetchJson('/v1/admin/gifts', { method: 'POST', body: form }), "Sovg'a qo'shildi");
    }
    if (ok) { closeModal(); renderGifts(el, ''); }
  };
}

async function renderTopups(el, state) {
  const list = await api(`/v1/admin/gifts/topups?state=${state}`);
  const support = can('support');
  const tab = (id) => `<a class="tab" href="#gifts/${id}" aria-pressed="${id === state}">${esc(TOPUP_STATUS[id])}${id === 'pending' ? ` · ${list.pending}` : ''}</a>`;
  const rows = list.items.map((t) => `<tr>
      <td>${esc(date(t.created_at))}</td>
      <td class="num"><b>${esc(som(t.amount_uzs))}</b></td>
      <td>${t.telegram_user_id ? `Telegram ID: <code>${esc(String(t.telegram_user_id))}</code>` : '<span class="muted">Telegram bog\'lanmagan</span>'}</td>
      <td>${t.status === 'rejected' ? esc(t.reject_reason) : esc(t.reviewed_by || '')}</td>
      <td><div class="toolbar">${support ? `<button class="btn" data-t="receipt" data-id="${esc(t.id)}">Chekni ko'rish</button>` : ''}
        ${support && t.status === 'pending' ? `<button class="btn primary" data-t="approve" data-id="${esc(t.id)}">Tasdiqlash</button>
        <button class="btn bad" data-t="reject" data-id="${esc(t.id)}">Rad etish</button>` : ''}</div></td></tr>`).join('');
  el.innerHTML = `
    <div class="tabs"><a class="tab" href="#gifts" aria-pressed="false">Katalog</a>${['pending', 'approved', 'rejected'].map(tab).join('')}</div>
    ${list.items.length ? `<div class="table-wrap"><table><thead><tr><th>Sana</th><th>Summa</th><th>Foydalanuvchi</th><th>Izoh</th><th></th></tr></thead>
      <tbody>${rows}</tbody></table></div>` : '<div class="empty">Bu yerda to\'lov yo\'q</div>'}
    <p class="muted">Chekdagi summa kartaga (Sozlamalar → Karta raqami) tushganini tekshiring. Tasdiqlansa, summa foydalanuvchining UZARO balansiga qo'shiladi.</p>`;
  el.querySelectorAll('[data-t]').forEach((b) => {
    b.onclick = async () => {
      const path = `/v1/admin/gifts/topups/${b.dataset.id}`;
      if (b.dataset.t === 'receipt') return showReceipt(`${path}/receipt`);
      if (b.dataset.t === 'approve') {
        if (await run(() => api(`${path}/approve`, { method: 'POST' }), "Balansga qo'shildi")) renderTopups(el, state);
        return undefined;
      }
      const reason = prompt('Rad etish sababi (foydalanuvchiga ko\'rinadi):');
      if (reason && reason.trim().length >= 3 && await run(() => api(`${path}/reject`, { method: 'POST', body: { reason: reason.trim() } }), 'Rad etildi')) {
        renderTopups(el, state);
      } else if (reason !== null) toast('Sabab kamida 3 ta harf bo\'lsin', true);
      return undefined;
    };
  });
}

// Money from UZARO to a user's balance (cashback, a promo bonus, goodwill); the app shows it as "Bonus".
function bonusForm() {
  const body = openModal('Balansga bonus', `
    <form class="stack" id="b-form">
      <div class="form-grid">
        <div class="field"><label for="b-tg">Telegram ID</label><input id="b-tg" type="number" min="1" required></div>
        <div class="field"><label for="b-amount">Summa (so'm)</label><input id="b-amount" type="number" min="100" max="5000000" step="100" required></div>
      </div>
      <div class="field"><label for="b-reason">Sabab (jurnalga yoziladi)</label><input id="b-reason" required minlength="3" maxlength="256" placeholder="Keshbek: noyabr aksiyasi"></div>
      <div><button class="btn primary" type="submit">Balansga qo'shish</button></div>
    </form>`);
  body.querySelector('#b-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      telegram_user_id: Number(body.querySelector('#b-tg').value),
      amount_uzs: Number(body.querySelector('#b-amount').value),
      reason: body.querySelector('#b-reason').value.trim(),
    };
    // The confirmation replaces the form in the shared modal; nothing to close afterwards.
    if (!(await confirmBox('Bonusni tasdiqlang', `${som(payload.amount_uzs)} → Telegram ID ${payload.telegram_user_id}`, "Qo'shish"))) return;
    const done = await run(() => api('/v1/admin/gifts/credit', { method: 'POST', body: payload }));
    if (done) toast(`Qo'shildi. Yangi balans: ${som(done.balance_uzs)}`);
  };
}
