'use strict';
// "Musiqa" page: songs for the app's music section. Files go straight to the UZARO server (no bot, no channel);
// several songs can be picked at once, each one is named from its file ("Ijrochi - Nomi.mp3") and can be edited later.
/* global api, run, esc, toast, openModal, closeModal, confirmBox, can, ERRORS, fetchJson, mb, $ */

const MUSIC_CATEGORIES = { uz_old: "O'zbekcha eski", uz_new: "O'zbekcha yangi", world: "Jahon qo'shiqlari", car: 'Mashina uchun' };
Object.assign(ERRORS, {
  NOT_AN_AUDIO: "Bu fayl MP3 yoki M4A qo'shiq emas", TITLE_REQUIRED: "Qo'shiq nomini kiriting", TRACK_NOT_FOUND: "Qo'shiq topilmadi",
  HTTP_413: 'Fayl juda katta (25 MB gacha)',
});

const minutes = (s) => (s ? `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` : '—');

async function renderMusic(el, arg) {
  const category = MUSIC_CATEGORIES[arg] ? arg : '';
  const list = await api(`/v1/admin/music?limit=500${category ? `&category=${category}` : ''}`);
  const support = can('support');
  const all = Object.values(list.counts).reduce((a, b) => a + b, 0);
  const tab = (id, label, n) => `<a class="tab" href="#music${id ? `/${id}` : ''}" aria-pressed="${id === category}">${esc(label)} · ${n}</a>`;
  const rows = list.items.map((t) => `<tr data-title="${esc(`${t.title} ${t.artist}`.toLowerCase())}">
      <td><b>${esc(t.title)}</b><br><span class="muted">${esc(t.artist || '—')}</span></td>
      <td>${esc(MUSIC_CATEGORIES[t.category] || t.category)}${t.active ? '' : ' <span class="pill bad">Yashirin</span>'}</td>
      <td>${esc(minutes(t.duration_seconds))} · ${esc(mb(t.size_bytes))}</td>
      <td><audio controls preload="none" src="${esc(t.audio_url)}"></audio></td>
      <td>${support ? `<div class="toolbar"><button class="btn" data-mu="edit" data-id="${esc(t.id)}">Tahrirlash</button>
        <button class="btn bad" data-mu="delete" data-id="${esc(t.id)}">O'chirish</button></div>` : ''}</td></tr>`).join('');
  el.innerHTML = `
    <div class="tabs">${tab('', 'Hammasi', all)}${Object.entries(MUSIC_CATEGORIES).map(([id, label]) => tab(id, label, list.counts[id] || 0)).join('')}</div>
    <div class="toolbar"><input id="mu-q" type="search" placeholder="Nomi yoki ijrochi" class="narrow">
      ${support ? '<button class="btn primary" id="mu-new" type="button">+ Qo\'shiq yuklash</button>' : ''}</div>
    ${list.items.length ? `<div class="table-wrap"><table><thead><tr><th>Qo'shiq</th><th>Bo'lim</th><th>Davomiyligi</th><th>Tinglash</th><th></th></tr></thead>
      <tbody id="mu-list">${rows}</tbody></table></div>` : '<div class="empty">Bu bo\'limda hali qo\'shiq yo\'q</div>'}
    <p class="muted">Qo'shiqlar serverga yuklanadi va ilovada darhol chiqadi. Bitta fayl 25 MB gacha, MP3 yoki M4A.</p>`;
  el.querySelector('#mu-new')?.addEventListener('click', () => uploadSongs(category || 'uz_new', el, arg));
  el.querySelector('#mu-q').oninput = (e) => {
    const q = e.target.value.trim().toLowerCase();
    el.querySelectorAll('#mu-list tr').forEach((row) => { row.hidden = q && !row.dataset.title.includes(q); });
  };
  el.querySelectorAll('[data-mu]').forEach((b) => { b.onclick = () => musicAction(b.dataset.mu, list.items.find((t) => t.id === b.dataset.id), el, arg); });
}

async function musicAction(act, track, el, arg) {
  if (act === 'edit') return editSong(track, el, arg);
  if (act === 'delete') {
    if (!(await confirmBox(`"${track.title}" ni o'chirish`, "Qo'shiq serverdan butunlay o'chiriladi.", "O'chirish"))) return undefined;
    await run(() => api(`/v1/admin/music/${track.id}`, { method: 'DELETE' }), "O'chirildi");
    return renderMusic(el, arg);
  }
  return undefined;
}

const categorySelect = (id, selected) => `<select id="${id}">${Object.entries(MUSIC_CATEGORIES)
  .map(([value, label]) => `<option value="${value}" ${value === selected ? 'selected' : ''}>${esc(label)}</option>`).join('')}</select>`;

function editSong(t, el, arg) {
  const body = openModal('Qo\'shiqni tahrirlash', `
    <form class="stack" id="mu-form">
      <div class="form-grid">
        <div class="field"><label for="mu-title">Nomi</label><input id="mu-title" required maxlength="200" value="${esc(t.title)}"></div>
        <div class="field"><label for="mu-artist">Ijrochi</label><input id="mu-artist" maxlength="200" value="${esc(t.artist)}"></div>
        <div class="field"><label for="mu-cat">Bo'lim</label>${categorySelect('mu-cat', t.category)}</div>
      </div>
      <label class="chip"><input type="checkbox" id="mu-active" ${t.active ? 'checked' : ''}> Ilovada ko'rsatilsin</label>
      <div><button class="btn primary" type="submit">Saqlash</button></div>
    </form>`);
  body.querySelector('#mu-form').onsubmit = async (e) => {
    e.preventDefault();
    const payload = {
      title: body.querySelector('#mu-title').value.trim(), artist: body.querySelector('#mu-artist').value.trim(),
      category: body.querySelector('#mu-cat').value, active: body.querySelector('#mu-active').checked,
    };
    if (await run(() => api(`/v1/admin/music/${t.id}`, { method: 'PUT', body: payload }), 'Saqlandi')) { closeModal(); renderMusic(el, arg); }
  };
}

function uploadSongs(category, el, arg) {
  const body = openModal("Qo'shiq yuklash", `
    <form class="stack" id="up-form">
      <div class="field"><label for="up-cat">Bo'lim</label>${categorySelect('up-cat', category)}</div>
      <div class="field"><label for="up-files">Fayllar (MP3, M4A — bir nechtasini birdan tanlash mumkin)</label>
        <input id="up-files" type="file" accept=".mp3,.m4a,audio/mpeg,audio/mp4" multiple required>
        <small>Fayl nomi "Ijrochi - Qo'shiq nomi.mp3" bo'lsa, ijrochi va nom o'zi ajratiladi.</small></div>
      <div><button class="btn primary" type="submit">Yuklash</button></div>
    </form>`);
  body.querySelector('#up-form').onsubmit = async (e) => {
    e.preventDefault();
    const files = [...body.querySelector('#up-files').files];
    const cat = body.querySelector('#up-cat').value;
    if (!files.length) return;
    closeModal();
    let done = 0;
    for (const file of files) {
      toast(`Yuklanmoqda ${done + 1}/${files.length}: ${file.name}`);
      const { title, artist } = nameOf(file.name);
      const form = new FormData();
      form.append('file', file);
      form.append('category', cat);
      form.append('title', title);
      form.append('artist', artist);
      form.append('duration_seconds', String(await durationOf(file)));
      if (await run(() => fetchJson('/v1/admin/music', { method: 'POST', body: form }))) done += 1;
    }
    toast(`${done} ta qo'shiq yuklandi${done < files.length ? `, ${files.length - done} tasi xato` : ''}`, done < files.length);
    if (location.hash.startsWith('#music')) renderMusic(el, arg);
  };
}

/** "Sevara - Bahor (2004).mp3" -> artist "Sevara", title "Bahor (2004)". */
function nameOf(fileName) {
  const base = fileName.replace(/\.[^.]+$/, '').replace(/_/g, ' ').trim();
  const at = base.indexOf(' - ');
  return at > 0 ? { artist: base.slice(0, at).trim().slice(0, 200), title: base.slice(at + 3).trim().slice(0, 200) || base.slice(0, 200) }
    : { artist: '', title: base.slice(0, 200) || 'Nomsiz' };
}

/** Song length in whole seconds read by the browser, 0 when it cannot tell within 5 s. */
function durationOf(file) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const audio = new Audio();
    const finish = (seconds) => { clearTimeout(timer); URL.revokeObjectURL(url); resolve(Number.isFinite(seconds) ? Math.round(seconds) : 0); };
    const timer = setTimeout(() => finish(0), 5000);
    audio.preload = 'metadata';
    audio.onloadedmetadata = () => finish(audio.duration);
    audio.onerror = () => finish(0);
    audio.src = url;
  });
}
