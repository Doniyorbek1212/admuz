'use strict';
// "UZARO AI" page: the model provider key (only written, never shown back: the server keeps it encrypted), the
// model name, the daily question limit per person, on/off, and a test question.
/* global api, run, esc, can, ERRORS, toast */

Object.assign(ERRORS, {
  AI_NOT_CONFIGURED: "AI kaliti kiritilmagan yoki AI o'chirilgan", AI_UNAVAILABLE: "Kalit yoki model ishlamadi — kalitni va model nomini tekshiring",
  AI_BUSY: "Model hozir band yoki kalit limiti tugagan. Birozdan so'ng urinib ko'ring", AI_EMPTY: "Model bo'sh javob qaytardi",
});

async function renderAi(el) {
  const ai = await api('/v1/admin/ai');
  const owner = can('owner');
  el.innerHTML = `
    <div class="kpis">
      <div class="kpi"><span class="label">Holati</span><span class="value">${ai.key_set && ai.enabled ? 'Ishlayapti' : ai.key_set ? "O'chirilgan" : 'Kalit yo\'q'}</span></div>
      <div class="kpi"><span class="label">24 soatda savollar</span><span class="value">${ai.stats.questions_24h}</span></div>
      <div class="kpi"><span class="label">24 soatda foydalanuvchilar</span><span class="value">${ai.stats.people_24h}</span></div>
      <div class="kpi"><span class="label">Jami suhbatlar</span><span class="value">${ai.stats.chats}</span></div>
    </div>
    <form class="stack" id="ai-form">
      <div class="form-grid">
        <div class="field"><label for="ai-key">API kalit ${ai.key_set ? `(saqlangan: <span class="mono">${esc(ai.key_hint)}</span>)` : ''}</label>
          <input id="ai-key" type="password" autocomplete="off" spellcheck="false" maxlength="400" ${owner ? '' : 'disabled'}
            placeholder="${ai.key_set ? "O'zgartirish uchun yangi kalitni kiriting" : 'AIza…'}">
          <span class="muted">Kalit faqat serverda shifrlangan holda saqlanadi. Ilovada va bu sahifada qayta ko'rinmaydi.</span></div>
        <div class="field"><label for="ai-model">Model</label><input id="ai-model" maxlength="64" value="${esc(ai.model)}" ${owner ? '' : 'disabled'}>
          <span class="muted">Masalan: gemini-3.8-flash (tez va arzon). Bu model band yoki yopiq bo'lsa, server o'zi zaxira modelga o'tadi.</span></div>
        <div class="field"><label for="ai-limit">Bir kishiga kunlik savollar</label><input id="ai-limit" type="number" min="1" max="10000" value="${ai.daily_limit}" ${owner ? '' : 'disabled'}></div>
      </div>
      <label class="chip" style="align-self:flex-start;white-space:nowrap"><input type="checkbox" id="ai-on" ${ai.enabled ? 'checked' : ''} ${owner ? '' : 'disabled'}> UZARO AI yoqilgan</label>
      ${owner ? `<div class="toolbar"><button class="btn primary" type="submit">Saqlash</button>
        <button class="btn" type="button" id="ai-test" ${ai.key_set ? '' : 'disabled'}>Sinab ko'rish</button></div>` : '<p class="muted">Faqat Egasi o\'zgartira oladi.</p>'}
      <p id="ai-reply" class="muted"></p>
    </form>
    <p class="muted">Foydalanuvchilar ilovada faqat "UZARO AI"ni ko'radi: qaysi model yoki kompaniya ishlatilgani hech qayerda
      ko'rsatilmaydi. Suhbatdan foydalanish uchun Telegram akkaunti tasdiqlangan bo'lishi kerak.</p>`;
  if (!owner) return;
  el.querySelector('#ai-form').onsubmit = async (e) => {
    e.preventDefault();
    const key = el.querySelector('#ai-key').value.trim();
    const body = { model: el.querySelector('#ai-model').value.trim(), daily_limit: Number(el.querySelector('#ai-limit').value), enabled: el.querySelector('#ai-on').checked };
    if (key) body.api_key = key;
    if (await run(() => api('/v1/admin/ai', { method: 'PUT', body }), 'Saqlandi')) renderAi(el);
  };
  el.querySelector('#ai-test').onclick = async (e) => {
    const button = e.currentTarget;
    if (button.disabled) return;
    button.disabled = true; // one paid test call at a time
    el.querySelector('#ai-reply').textContent = 'Tekshirilmoqda…';
    const res = await run(() => api('/v1/admin/ai/test', { method: 'POST' })).finally(() => { button.disabled = false; });
    el.querySelector('#ai-reply').textContent = res ? `Javob: ${res.reply}` : '';
    if (res) toast('Kalit ishlayapti');
  };
}
