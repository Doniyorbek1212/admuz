# Claude Code uchun buyruq: 30 ta premium sovg'ani loyihaga qo'shish

Quyidagini UZARO loyihasida (`C:\Users\Comp X\Desktop\UZARO`) ochilgan Claude Code sessiyasiga to'liq nusxalab bering.

---

UZARO ilovasiga 30 ta yangi premium sovg'a show'larini qo'sh. Fayllar tayyor, ularni qayta yaratma va o'zgartirma.

## Manba: faqat shu fayllarni ol
Papka: `C:\Users\Comp X\Desktop\UZARO\gift_renders\`
- `manifest.json`: 30 sovg'aning ro'yxati. Har bir yozuvda `id`, `tier` (1–4), `price_uzs`, `duration_ms`, `title` {uz, ru, en} va `files` {show, icon, sound} bor.
- `<id>.webp`: to'liq ekran show. 540×960, 24 fps, shaffof (straight alpha), animated WebP, loop count 1 (bir marta o'ynaydi). Hajmi 2,5–4 MB.
- `<id>_icon.webp`: sovg'a tanlash ro'yxati uchun ikonka. 192×192, 15 fps, 2 s, loop count 0 (cheksiz aylanadi), ≤150 KB.
- `<id>.mp3`: tovush. Mono, uzunligi show bilan bir xil, eng muhim lahzaga sinxronlangan.
- `CREDITS.txt`: modellar va tovushlar mualliflari. Ba'zi modellar CC BY litsenziyali, shuning uchun mualliflarni ilovada ko'rsatish majburiy.

Quyidagilarni OLMA: `gift_renders/source/`, `*_preview.jpg` (faqat ko'rib chiqish uchun), `lookdev/`, `scripts/`, `models/`.

## Avval o'rgan, keyin reja tuz
1. Mavjud sovg'a tizimini o'qi:
   - `mobile/lib/features/gifts/`, ayniqsa `gift_video.dart`, `gift_effects.dart`, `gift_widgets.dart`, `gifts_screen.dart`
   - `mobile/lib/core/api/gift_models.dart`, `sado_api.dart`
   - `server/app/` ichidagi sovg'a modeli, API va media berish qismi, `alembic/`
2. Sovg'alar hozir qanday saqlanadi, narxlanadi, yuboriladi va o'ynaladi, shuni aniqla. Yangi sovg'alarni shu mavjud yo'l bilan qo'sh, parallel ikkinchi tizim qurma.
3. Kodga tegishdan oldin menga qisqa reja ko'rsat: qaysi fayllar o'zgaradi, fayllar qayerga joylashadi, migratsiya kerakmi.

## Qanday ishlashi kerak
- **Joylashuv.** Show va mp3 jami ~80–100 MB. Ularni ilova ichiga (Flutter assets) qo'shma. Server media orqali ber (masalan `server/media/gifts/`, loyiha qoidasiga mos), ilova esa kerak bo'lganda yuklab, keshlasin. Ikonkalar kichik: ularni oldindan yuklash yoki assets'ga qo'yish mumkin, mavjud usulga qara.
- **Katalog.** `manifest.json` dan serverdagi sovg'alar ro'yxatini to'ldir: id, tier, narx, davomiylik, 3 tildagi nom. Kerak bo'lsa alembic migratsiya yoz. Narxni server hal qiladi, ilova yuborgan narxga ishonma. Noma'lum `id` rad etilsin. Narxlarni mendan so'ramasdan o'zgartirma.
- **O'ynatish.** Sovg'a yuborilganda yoki kelganda chat ustida to'liq ekran, shaffof overlay chiqsin.
  - Avval webp va mp3 ikkalasi yuklanib bo'lishini kut, keyin birinchi kadr bilan tovushni bir vaqtda boshla. Aks holda sinxron buziladi.
  - Show bir marta o'ynasin. Ehtiyot uchun overlay `duration_ms` dan keyin baribir yopilsin.
  - Kadrni 540×960 dan kattaroq dekodlama, xotirani tejash uchun `cacheWidth` va `cacheHeight` dan foydalan.
  - Overlay ostidagi chat bilan ishlashni to'smasin yoki teginishda yopilsin, mavjud xatti-harakatga mos qil.
  - Telefon jim rejimda bo'lsa va ilovaning ovoz sozlamasi bo'lsa, ularni hurmat qil.
- **Sovg'a tanlash ekrani.** `_icon.webp` ni aylanib turgan holda ko'rsat, yoniga `title` (joriy til) va narxni qo'y. Tierlar bo'yicha guruhlash mavjud bo'lsa, ishlat.
- **Mualliflar.** `CREDITS.txt` matnini ilovaning "Litsenziyalar / Ilova haqida" bo'limida ko'rsat.
- Mavjud eski sovg'alarni o'chirma.

## Tekshiruv
- `flutter analyze` toza bo'lsin. Mavjud testlar o'tsin. Server testlari (`pytest`) o'tsin.
- Katalog parseri va narxni serverda tekshirish uchun test qo'sh.
- Kamida 3 ta sovg'ani qurilmada yoki emulatorda sinab ko'r:
  - bitta tier 1 (`rose_bloom`)
  - bitta og'ir tier 4 (`universe` yoki `treasure_chest`)
  - bitta qorong'i va bitta och fonli chatda
- Har birida tekshir: shaffoflik to'g'ri, tovush sinxron, bir marta o'ynab yopiladi, xotira keskin oshmaydi.
- Oxirida yoz: nima qilindi, qaysi fayllar o'zgardi, nima tekshirilmadi.

Commit yoki deploy'ni mendan so'ramasdan qilma.
