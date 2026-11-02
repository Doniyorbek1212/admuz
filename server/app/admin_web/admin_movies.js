'use strict';
// "Kinolar" page: films and series for the app's Töplam section. Videos go up in resumable chunks; the server
// compresses each one and posts it to the Telegram channel, then deletes its own copy.
/* global api, run, esc, toast, openModal, closeModal, confirmBox, can, date, ERRORS, ApiError, state, $ */

const MOVIE_CATEGORIES = [
  'Jangari', 'Komediya', 'Drama', 'Melodrama', 'Tarixiy', 'Fantastika', 'Sarguzasht', 'Detektiv', 'Triller', "Qo'rqinchli",
  'Multfilm', 'Oilaviy', 'Hujjatli', "O'zbek kinolari", 'Turk seriallari', 'Koreys seriallari', 'Hind kinolari', 'Rus kinolari',
];
const VIDEO_STATUS = {
  uploading: ['Yuklanmoqda', 'info'], queued: ['Navbatda', 'warn'], processing: ['Siqilmoqda', 'gold'], ready: ['Tayyor', 'ok'], failed: ['Xato', 'bad'],
};
Object.assign(ERRORS, {
  DISK_FULL: "Serverda joy yetmaydi: avval navbatdagi kinolar tugashini kuting", NOT_A_VIDEO: 'Bu fayl video emas', FILE_TOO_LARGE: 'Fayl juda katta',
  VIDEO_PROCESSING: "Video hozir siqilmoqda, tugashini kuting", POSTER_NOT_AN_IMAGE: "Poster JPG, PNG yoki WebP rasm bo'lishi kerak",
  SOURCE_MISSING: 'Asl fayl serverda yo\'q, videoni o\'chirib qayta yuklang', MEDIA_TYPE_NOT_SUPPORTED: "Bu fayl turi qo'llanmaydi",
});

const mb = (n) => `${(Number(n || 0) / 1048576).toLocaleString('uz-UZ', { maximumFractionDigits: 1 })} MB`;
const gb = (n) => `${(Number(n || 0) / 1073741824).toLocaleString('uz-UZ', { maximumFractionDigits: 1 })} GB`;
const hours = (s) => `${Math.floor(s / 3600)} soat ${Math.floor((s % 3600) / 60)} daqiqa`;
const uploads = new Map(); // video id -> percent, for uploads running in this tab

async function renderMovies(el) {
  clearTimeout(renderMovies.timer);
  const [s, list] = await Promise.all([api('/v1/admin/movies/stats'), api('/v1/admin/movies?limit=200')]);
  const saved = s.ready_original_bytes ? Math.round(100 - (s.ready_compressed_bytes * 100) / s.ready_original_bytes) : 0;
  const support = can('support');
  el.innerHTML = `
    ${s.configured ? '' : `<div class="card warn-box">Telegram kanal sozlanmagan: serverda <code>SADO_BILLING_TG_API_ID</code>, <code>SADO_BILLING_TG_API_HASH</code>,
      <code>SADO_BILLING_MOVIES_BOT_TOKEN</code>, <code>SADO_BILLING_MOVIES_CHANNEL</code> kerak. Yuklangan kinolar navbatda kutib turadi.</div>`}
    <div class="kpis">
      <div class="kpi"><span class="label">Kino va seriallar</span><span class="value">${s.titles}</span><span class="sub">${s.videos.ready} ta video tayyor · ${hours(s.ready_duration_seconds)}</span></div>
      <div class="kpi"><span class="label">Telegramda saqlanmoqda</span><span class="value">${esc(gb(s.ready_compressed_bytes))}</span><span class="sub">${s.channel ? `@${esc(s.channel)}` : 'kanal yo\'q'} · serverda 0 MB</span></div>
      <div class="kpi money"><span class="label">Siqish tejadi</span><span class="value">${saved}%</span><span class="sub">Asl fayllar ${esc(gb(s.ready_original_bytes))}</span></div>
      <div class="kpi"><span class="label">Serverdagi vaqtinchalik fayllar</span><span class="value">${esc(gb(s.work_bytes))}</span><span class="sub">Bo'sh joy ${esc(gb(s.disk_free_bytes))} / ${esc(gb(s.disk_total_bytes))}</span></div>
    </div>
    <div class="queues">
      ${['uploading', 'queued', 'processing', 'failed'].map((k) => `<span class="queue${s.videos[k] ? '' : ' zero'}"><span>${esc(VIDEO_STATUS[k][0])}</span><b>${s.videos[k]}</b></span>`).join('')}
    </div>
    <div class="toolbar"><input id="mv-q" type="search" placeholder="Nomi bo'yicha qidirish" class="narrow">
      ${support ? '<button class="btn primary" id="mv-new" type="button">+ Kino yoki serial</button>' : ''}</div>
    ${list.items.length ? `<div class="grid-cards" id="mv-list">${list.items.map(movieCard).join('')}</div>` : '<div class="empty">Hali kino qo\'shilmagan</div>'}
    <p class="muted">Video yuklangach server uni 720p gacha siqadi va Telegram kanaliga joylaydi, so'ng o'zidan o'chiradi. Bir vaqtda bitta video siqiladi.</p>`;
  el.querySelector('#mv-new')?.addEventListener('click', () => editTitle(null, el));
  el.querySelector('#mv-q').oninput = (e) => {
    const q = e.target.value.trim().toLowerCase();
    el.querySelectorAll('#mv-list .item').forEach((card) => { card.hidden = q && !card.dataset.title.includes(q); });
  };
  el.querySelectorAll('[data-mv]').forEach((b) => { b.onclick = () => movieAction(b.dataset.mv, b.dataset.id, list.items, el); });
  // Keep progress bars moving while something is still on the server.
  const busy = Object.entries(s.videos).some(([k, n]) => n && ['queued', 'processing'].includes(k)) || uploads.size;
  if (busy) renderMovies.timer = setTimeout(() => { if (location.hash.startsWith('#movies') && $('#modal').hidden) renderMovies(el); }, 5000);
}

function movieCard(t) {
  const support = can('support');
  const videos = t.videos.map((v) => {
    const label = v.season || v.episode ? `${v.season ? `${v.season}-fasl ` : ''}${v.episode ? `${v.episode}-qism` : ''}` : 'Film';
    const local = uploads.get(v.id);
    const percent = local !== undefined ? local : v.percent;
    const bar = local !== undefined || ['processing'].includes(v.status)
      ? `<div class="progress" title="${percent}%"><span style="width:${percent}%"></span></div><small class="muted">${local !== undefined ? 'Brauzerdan yuklanmoqda' : v.stage === 'telegram' ? 'Telegramga yuborilmoqda' : 'Siqilmoqda'} ${percent}%</small>` : '';
    const sizes = v.status === 'ready' ? `${esc(mb(v.original_bytes))} → <b>${esc(mb(v.compressed_bytes))}</b> · ${v.height}p` : esc(mb(v.original_bytes));
    return `<li><div class="toolbar"><b>${esc(label)}</b>${v.name ? ` ${esc(v.name)}` : ''}${pillOf(v.status)}<span class="muted">${sizes}</span></div>${bar}
      ${v.error ? `<small class="bad-text">${esc(v.error)}</small>` : ''}
      ${support ? `<div class="toolbar">${v.status === 'failed' ? `<button class="btn" data-mv="retry" data-id="${esc(v.id)}">Qayta urinish</button>` : ''}
        ${v.status === 'uploading' && local === undefined ? `<button class="btn" data-mv="resume" data-id="${esc(v.id)}">Davom ettirish</button>` : ''}
        ${v.status !== 'processing' ? `<button class="btn bad" data-mv="delvideo" data-id="${esc(v.id)}">O'chirish</button>` : ''}</div>` : ''}</li>`;
  }).join('');
  return `<article class="item" data-title="${esc(t.title.toLowerCase())}">
    <div class="media">${t.poster_url ? `<img src="${esc(t.poster_url)}" alt="" loading="lazy">` : '<span class="muted">Poster yo\'q</span>'}</div>
    <div class="body">
      <div class="toolbar"><span class="pill info">${t.kind === 'series' ? 'Serial' : 'Film'}</span>${t.active ? '' : '<span class="pill bad">Yashirin</span>'}${t.year ? `<span class="muted">${t.year}</span>` : ''}</div>
      <h4>${esc(t.title)}</h4>
      ${t.categories.length ? `<p class="muted">${esc(t.categories.join(' · '))}</p>` : ''}
      <ul class="videos">${videos || '<li class="muted">Video yuklanmagan</li>'}</ul>
    </div>
    ${support ? `<div class="actions"><button class="btn primary" data-mv="video" data-id="${esc(t.id)}">+ Video</button>
      <button class="btn" data-mv="poster" data-id="${esc(t.id)}">Poster</button><button class="btn" data-mv="edit" data-id="${esc(t.id)}">Tahrirlash</button>
      <button class="btn bad" data-mv="delete" data-id="${esc(t.id)}">O'chirish</button></div>` : ''}
  </article>`;
}

const pillOf = (key) => { const [label, tone] = VIDEO_STATUS[key] || [key, 'info']; return `<span class="pill ${tone}">${esc(label)}</span>`; };

async function movieAction(act, id, items, el) {
  const title = items.find((t) => t.id === id);
  if (act === 'edit') return editTitle(title, el);
  if (act === 'poster') return pickFile('image/jpeg,image/png,image/webp', async (file) => {
    const form = new FormData();
    form.append('file', file);
    await run(() => fetchJson(`/v1/admin/movies/${id}/poster`, { method: 'POST', body: form }), 'Poster saqlandi');
    renderMovies(el);
  });
  if (act === 'video') return addVideo(title, el);
  if (act === 'resume') return pickFile('video/*,.mkv,.avi,.ts', (file) => resumeUpload(id, file, el));
  if (act === 'retry') { await run(() => api(`/v1/admin/movies/videos/${id}/retry`, { method: 'POST' }), 'Navbatga qaytarildi'); return renderMovies(el); }
  if (act === 'delvideo') {
    if (!(await confirmBox("Videoni o'chirish", "Video serverdan va Telegram kanalidan o'chiriladi.", "O'chirish"))) return undefined;
    await run(() => api(`/v1/admin/movies/videos/${id}`, { method: 'DELETE' }), "Video o'chirildi");
    return renderMovies(el);
  }
  if (act === 'delete') {
    if (!(await confirmBox(`"${title.title}" ni o'chirish`, "Barcha videolari serverdan va Telegram kanalidan o'chiriladi.", "O'chirish"))) return undefined;
    await run(() => api(`/v1/admin/movies/${id}`, { method: 'DELETE' }), "O'chirildi");
    return renderMovies(el);
  }
  return undefined;
}

function editTitle(t, el) {
  const current = new Set(t?.categories || []);
  const extra = [...current].filter((c) => !MOVIE_CATEGORIES.includes(c));
  const chips = [...MOVIE_CATEGORIES, ...extra].map((c) =>
    `<label class="chip"><input type="checkbox" value="${esc(c)}" ${current.has(c) ? 'checked' : ''}> ${esc(c)}</label>`).join('');
  const body = openModal(t ? 'Tahrirlash' : 'Yangi kino yoki serial', `
    <form class="stack" id="mv-form">
      <div class="form-grid">
        <div class="field"><label for="mv-kind">Turi</label><select id="mv-kind"><option value="movie">Film</option><option value="series" ${t?.kind === 'series' ? 'selected' : ''}>Serial</option></select></div>
        <div class="field"><label for="mv-title">Nomi</label><input id="mv-title" required maxlength="200" value="${esc(t?.title || '')}"></div>
        <div class="field"><label for="mv-year">Yili</label><input id="mv-year" type="number" min="1888" max="2100" value="${esc(t?.year || '')}"></div>
        <div class="field"><label for="mv-country">Davlati</label><input id="mv-country" maxlength="80" value="${esc(t?.country || '')}"></div>
        <div class="field"><label for="mv-lang">Tili</label><input id="mv-lang" maxlength="40" placeholder="O'zbek tilida" value="${esc(t?.language || '')}"></div>
        <div class="field"><label for="mv-sort">Tartib (katta — yuqorida)</label><input id="mv-sort" type="number" min="-1000" max="1000" value="${esc(t?.sort_order || 0)}"></div>
      </div>
      <div class="field"><span class="label">Kategoriyalar</span><div class="chips" id="mv-cats">${chips}</div>
        <input id="mv-cat-new" maxlength="40" placeholder="Boshqa kategoriya (vergul bilan)"></div>
      <div class="field"><label for="mv-desc">Tavsif</label><textarea id="mv-desc" maxlength="3000">${esc(t?.description || '')}</textarea></div>
      <label class="chip"><input type="checkbox" id="mv-active" ${t?.active === false ? '' : 'checked'}> Ilovada ko'rsatilsin</label>
      <div><button class="btn primary" type="submit">Saqlash</button></div>
    </form>`);
  body.querySelector('#mv-form').onsubmit = async (e) => {
    e.preventDefault();
    const cats = [...body.querySelectorAll('#mv-cats input:checked')].map((c) => c.value)
      .concat(body.querySelector('#mv-cat-new').value.split(',').map((c) => c.trim()).filter(Boolean));
    const payload = {
      kind: body.querySelector('#mv-kind').value, title: body.querySelector('#mv-title').value.trim(),
      year: Number(body.querySelector('#mv-year').value) || null, country: body.querySelector('#mv-country').value.trim(),
      language: body.querySelector('#mv-lang').value.trim(), sort_order: Number(body.querySelector('#mv-sort').value) || 0,
      genres: [...new Set(cats)].join(', ').slice(0, 200), description: body.querySelector('#mv-desc').value.trim(), active: body.querySelector('#mv-active').checked,
    };
    const ok = await run(() => api(t ? `/v1/admin/movies/${t.id}` : '/v1/admin/movies', { method: t ? 'PUT' : 'POST', body: payload }), 'Saqlandi');
    if (ok) { closeModal(); renderMovies(el); }
  };
}

function addVideo(t, el) {
  const series = t.kind === 'series';
  const next = Math.max(0, ...t.videos.map((v) => v.episode)) + 1;
  const body = openModal(`${t.title}: video yuklash`, `
    <form class="stack" id="vd-form">
      ${series ? `<div class="form-grid"><div class="field"><label for="vd-season">Fasl</label><input id="vd-season" type="number" min="0" max="100" value="1"></div>
        <div class="field"><label for="vd-ep">Qism</label><input id="vd-ep" type="number" min="0" max="10000" value="${next}"></div></div>` : ''}
      <div class="field"><label for="vd-name">Nomi (ixtiyoriy)</label><input id="vd-name" maxlength="200" placeholder="${series ? 'Masalan: Uchrashuv' : 'Masalan: 2-qism'}"></div>
      <div class="field"><label for="vd-file">Video fayl (MP4, MKV, AVI, MOV)</label><input id="vd-file" type="file" accept="video/*,.mkv,.avi,.ts" required>
        <small>Sahifani yopmang: fayl bo'laklab yuboriladi, uzilsa "Davom ettirish" bilan qolgan joyidan davom etadi.</small></div>
      <div><button class="btn primary" type="submit">Yuklashni boshlash</button></div>
    </form>`);
  body.querySelector('#vd-form').onsubmit = async (e) => {
    e.preventDefault();
    const file = body.querySelector('#vd-file').files[0];
    if (!file) return;
    const video = await run(() => api(`/v1/admin/movies/${t.id}/videos`, {
      method: 'POST',
      body: {
        season: Number(body.querySelector('#vd-season')?.value || 0), episode: Number(body.querySelector('#vd-ep')?.value || 0),
        name: body.querySelector('#vd-name').value.trim(), file_name: file.name.slice(0, 255), size_bytes: file.size,
      },
    }));
    if (!video) return;
    closeModal();
    sendChunks(video.id, file, 0, video.chunk_bytes, el);
    renderMovies(el);
  };
}

async function resumeUpload(id, file, el) {
  const v = await run(() => api(`/v1/admin/movies/videos/${id}`));
  if (!v) return;
  if (v.original_bytes !== file.size) { toast('Bu boshqa fayl: hajmi mos kelmadi', true); return; }
  const s = await api('/v1/admin/movies/stats');
  sendChunks(id, file, v.uploaded_bytes, s.chunk_bytes, el);
  renderMovies(el);
}

async function sendChunks(id, file, start, chunk, el) {
  let offset = start;
  let failures = 0;
  uploads.set(id, Math.floor((offset * 100) / file.size));
  while (offset < file.size) {
    const piece = file.slice(offset, Math.min(file.size, offset + chunk));
    try {
      const res = await fetch(`/v1/admin/movies/videos/${id}/content?offset=${offset}`, {
        method: 'PUT', headers: { 'X-Admin-Key': state.key, 'Content-Type': 'application/octet-stream' }, body: piece,
      });
      if (res.status === 409) {
        // The server has a different amount (an earlier tab, a retried request): continue from its offset.
        const detail = (await res.json().catch(() => ({})))?.detail || {};
        if (detail.code === 'WRONG_OFFSET') { offset = Number(detail.message); continue; }
        throw new ApiError(detail.code || 'HTTP_409', 409);
      }
      if (!res.ok) {
        const detail = (await res.json().catch(() => ({})))?.detail || {};
        throw new ApiError(detail.code || `HTTP_${res.status}`, res.status);
      }
      offset += piece.size;
      failures = 0;
      uploads.set(id, Math.floor((offset * 100) / file.size));
      updateBar(id);
    } catch (e) {
      failures += 1;
      if (e instanceof ApiError && e.status < 500 && e.status !== 429) { toast(ERRORS[e.code] || `Xatolik: ${e.code}`, true); break; }
      if (failures > 5) { toast("Yuklash to'xtadi: internetni tekshirib, \"Davom ettirish\" ni bosing", true); break; }
      await new Promise((r) => { setTimeout(r, 2000 * failures); });
    }
  }
  uploads.delete(id);
  if (offset >= file.size) toast(`${file.name} yuklandi, siqish navbatiga qo'yildi`);
  if (location.hash.startsWith('#movies')) renderMovies(el);
}

function updateBar(id) {
  const percent = uploads.get(id);
  const card = document.querySelector(`[data-id="${CSS.escape(id)}"]`)?.closest('li');
  const bar = card?.querySelector('.progress span');
  if (bar) bar.style.width = `${percent}%`;
  const label = card?.querySelector('.progress + small');
  if (label) label.textContent = `Brauzerdan yuklanmoqda ${percent}%`;
}

function pickFile(accept, onFile) {
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = accept;
  input.onchange = () => { if (input.files[0]) onFile(input.files[0]); };
  input.click();
}

async function fetchJson(path, init) {
  const res = await fetch(path, { ...init, headers: { 'X-Admin-Key': state.key } });
  if (!res.ok) {
    const detail = (await res.json().catch(() => ({})))?.detail || {};
    throw new ApiError(detail.code || `HTTP_${res.status}`, res.status);
  }
  return res.json();
}
