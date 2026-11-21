# Claude Code uchun: Sado funksiyalarini raqobatchilar bilan tenglashtirish prompti

Quyidagi matnni loyiha ildizida ishlayotgan Claude Code sessiyasiga to‘liq yuboring.

---

## ROL VA MAQSAD

Sen `C:\Users\Comp X\Desktop\sado` loyihasida ishlayotgan katta tajribali Flutter/Dart, TDLib, mobil xavfsizlik va mahsulot muhandisisan. Maqsad — Sado’ni Plus Messenger, Nicegram, AKA Messenger va Graph Messenger’da ommaga taqdim etilgan foydali imkoniyatlar bilan solishtirish; Sado’da yo‘qlarini xavfsiz va barqaror tarzda qo‘shish; qisman borlarini to‘liq, tushunarli va professional darajaga olib chiqish.

Bu topshiriq faqat tahlil yoki roadmap yozish bilan tugamaydi. Avval mavjud kodni va loyiha qoidalarini tekshir, keyin bosqichma-bosqich real implementatsiya qil. Ish bir necha katta bosqichga bo‘linsa, birinchi xavfsiz va mustaqil bosqichni to‘liq bajar, qolganini yakuniy hisobotda aniq ko‘rsat. Muammo chiqsa, bog‘liq bo‘lmagan ishni davom ettir.

Foydalanuvchi bilan ishlash tili — o‘zbekcha. Kod nomlari, API va texnik atamalarni inglizcha qoldirish mumkin.

## LOYIHA HAQIDA MA’LUM BO‘LGANLAR

- Mobil ilova: Flutter/Dart, Android va iOS.
- Telegram integratsiyasi: TDLib JSON FFI, typed API `tdlib_ex`, update’larni isolate’da qabul qilish.
- Ilova holati: Riverpod; Telegram obyektlari TDLib update’laridan xotira keshiga keladi.
- Backend: `server/` ichida FastAPI; PostgreSQL/Redis bilan Sado billing, profil va qo‘shimcha xizmatlari. Telegram sessiyasi/xabarlari backend’ga yuborilmasligi kerak.
- Asosiy hujjatlar: `README.md`, `mobile/README.md`, `docs/monetization/`, `docs/security-audit.md` (mavjud bo‘lsa). Repo ichidagi `AGENTS.md`, `.claude/` qoidalari va boshqa contributor ko‘rsatmalarini albatta topib o‘qi.
- Sado README’sida tilga olingan funksiyalar: Telegram chat va media, Stories, papkalar/tablar, ko‘pi bilan 5 akkaunt, yashirin chatlar, PIN/app lock, Ghost mode, yuklab olish menejeri, tarjima va xabar xulosasi, AI matn vositalari, stikerlar, kontakt o‘zgarishlari, muhim xabarlar, maxsus forward, Business quick replies va boshqalar.
- Hujjat va kodda farqlar bo‘lishi mumkin. Masalan, README qo‘ng‘iroqlarni yo‘q deb aytishi mumkin, holbuki qo‘ng‘iroq modullari mavjud; xavfsizlik auditi esa guruh qo‘ng‘irog‘i E2EE holatini tasdiqlanmagan deb ko‘rsatadi. Hujjatdagi gapni kod bilan tekshirmasdan haqiqat deb qabul qilma.

## RAQOBATCHI MANBALARI

Funksiyalarni faqat quyidagi ochiq sahifalar va ilova tavsiflarida ko‘rsatilgan doirada solishtir. Saytlar versiya, platforma, region va pullik reja bo‘yicha farq qilishi mumkin. Eski blog/FAQ bandini hozirgi build’da ishlaydi deb taxmin qilma.

- Plus: https://plusmessenger.org/ va https://play.google.com/store/apps/details?id=org.telegram.plus
- Nicegram: https://nicegram.me/ , https://nicegram.me/features , https://nicegram.me/guides , https://apps.apple.com/us/app/nicegram-dual-telegram-x-ai/id1608870673
- AKA: https://akamessenger.org/ va https://play.google.com/store/apps/details?id=org.aka.messenger
- Graph: https://www.graphmessenger.com/uz , https://mail.graphmessenger.com/en/features , https://play.google.com/store/apps/details?id=ir.ilmili.telegraph
- TDLib: https://core.telegram.org/tdlib/docs/ va https://core.telegram.org/tdlib/getting-started

Har bir raqobatchi funksiyasiga dalil manbasi, platforma/versiya sharti va holatini (hozirgi tavsifda bor, eski/historik, noma’lum, pullik yoki regionga bog‘liq) yoz. Bir raqobatchining marketing da’vosini Sado uchun xavfsizlik kafolati deb ko‘rsatma.

## AVVAL AUDIT QIL — KEYIN IMPLEMENTATSIYA

1. `pwd`, git branch/status va repo qoidalarini tekshir. Foydalanuvchining mavjud o‘zgarishlarini hech qachon o‘chirib yuborma, reset/revert qilma va o‘zingniki deb qabul qilma. Xususan untracked fayllar, `docs/security-audit.md` kabi fayllar mavjud bo‘lsa ularni asra.
2. `README.md`, `mobile/pubspec.yaml`, `mobile/lib/`, `server/app/`, CI va xavfsizlik/billing hujjatlarini ko‘r. Asosiy ekranlar va state boshqaruvini xaritala.
3. Har bir raqobatchi funksiyasi uchun Sado holatini quyidagilardan biri qilib belgilab, dalil fayl/satrlarini yoz:
   - **MAVJUD** — real ishlaydigan UI + state + Telegram/API amali bor.
   - **QISMAN** — o‘xshash imkoniyat bor, ammo raqobatchidagi oqim yoki asosiy holatlar yo‘q.
   - **FAQAT API/STATE** — model/API kodi bor, foydalanuvchiga to‘liq UI yo‘q.
   - **TOPILMADI** — kod qidiruvi va tegishli fayllar ko‘rigida implementatsiya aniqlanmadi.
   - **TEKSHIRISH KERAK** — README, kod, platforma yoki xavfsizlik holati o‘zaro zid.
4. `rg` bilan qidirishning o‘zi yetarli emas. Ehtimoliy modul, UI chaqiruv nuqtasi, state, permission, saqlash va platforma kodini ochib ko‘r. “Yo‘q” degan xulosa uchun qidirilgan nomlar/sinonimlarni audit jadvalida ko‘rsat.
5. Auditdan so‘ng quyidagi guruhlarni qamrab oluvchi parity jadvali yarat:
   - akkaunt va akkaunt sessiyasini ko‘chirish;
   - chat tablari, filtrlar, custom kategoriyalar, quick links, timeline;
   - auto-reply, quick reply va bulk amallar;
   - forward tahriri va link/content extractor;
   - AI: chat tahlili, xulosa, javob loyihasi, matn tahriri, tasvir, model tanlash;
   - translation va voice input/transcription;
   - maxfiylik: hidden chat/account, lock, notification, app switcher;
   - kontakt qaydlari va online ogohlantirishlari;
   - media, downloader, voice effects, video note, call recording;
   - tema, chat ko‘rinishi, til, sozlama backup/restore;
   - Telegram asosiy funksiyalari va Telegram API/TDLib versiya muvofiqligi.

Audit jadvalini `docs/feature-parity-audit.md` fayliga yoz. Bu auditni yozib, ishni to‘xtatma.

## RAQOBATCHILARDA UCHRAYDIGAN FUNKSIYALAR — TEKSHIRILADIGAN TALABLAR

Quyidagilarni Sado bilan solishtir. Sado’da allaqachon to‘liq bo‘lsa qayta yozma; qisman bo‘lsa farqini belgila va yaxshila.

### A. Akkauntlar va backup

- Bir ilovada ko‘p akkaunt, tez almashish, qidiruvli account manager, akkauntga nom/rang berish.
- Plus’dagi 10 tagacha, Nicegram’dagi iOS/Android bo‘yicha yuqori limitlar, Graph’dagi unlimited degan da’volarni qayd et; Sado uchun ko‘r-ko‘rona “cheksiz” limit qo‘yma. Qurilma xotirasi, TDLib instance soni, batareya va tarmoq yukiga qarab amaliy limit tanla.
- Akkaunt sessiyalarini export/import/backup, qurilmaga ko‘chirish va restore. Sessiya fayli akkauntga kirish huquqini berishi mumkin: shifrlash, parol, vaqtinchalik faylni o‘chirish, biometric/PIN gate, root/jailbreak risk UX va aniq ogohlantirish bo‘lsin. Cloud backup faqat aniq opt-in va himoyalangan bo‘lsin.
- Hidden account / Double Bottom: Sado’dagi hidden chats bilan aralashtirma. Auth holati, bildirishnomalar, qidiruv, account switcher va app switcher’da maxfiylikni tekshir.

### B. Chat tashkil qilish va navigatsiya

- Plus uslubidagi tablar: users, groups, channels, bots, favorites, unread, admin/creator; tablarni yashirish, qayta tartiblash va filtrlarini sozlash.
- Telegram papkalari va Sado lokal kategoriyalarini farqlash; kategoriya saqlash/restore va sozlamalar backup’iga qo‘shish.
- Har xil chat sorting, default chat folder/list, tab badge/unread counter.
- Graph Timeline: foydalanuvchi tanlagan kanal/chat manbalaridan birlashtirilgan, paginated feed. Read state va Telegram chat unread count’ini tasodifan buzma.
- Quick Links/Chat Bar: chat, folder, link, bot yoki ekran shortcut; uzun bosолт/drag UX, accessibility label.
- Chat list bulk selection: read/unread, mute/unmute, archive/unarchive, pin/unpin. Amalni tasdiqlash va qisman xato yuz bersa natijani ko‘rsatish.

### C. Xabar, forward va javob avtomatizatsiyasi

- Forward without quote; bitta va bir nechta xabar matni/caption’ini tahrirlash; link/text replace, prefix/suffix, tartiblash, quote/source va preview boshqaruvi; media albomini joylashtirish.
- Maxsus Link Extractor: xabardan URL, username, email, phone, hashtag/bot linklarni ajratish va nusxalash. Matnni xavfsiz parse qil; link safety tekshiruvini chetlab o‘tma.
- Quick replies/shablonlar: Sado’dagi Business Quick Replies real UI va scope’ini tekshir; barcha chat turlarida ishlashi kerak degan taxmin qilma. Shortcut, qidiruv, variable placeholder, edit/delete, tartiblash va backup’ni ko‘rib chiq.
- Auto Answer/Auto Reply: qoida, vaqt jadvali, chat/kontakt allowlist/blocklist, faqat bir marta javob berish, loop/botdan-botga cheklov, mute va off holati.
- Auto-reply’ni “app yopiq bo‘lsa ham ishlaydi” deb va’da qilma. Android/iOS background cheklovlarini tushuntir. Serverga Telegram user session yuborib doimiy ishlashni foydalanuvchi ruxsatisiz joriy etma.
- Message collapse/expand va uzun xabar o‘qish qulayligi.

### D. AI, tarjima va ovoz

- Sado’dagi Telegram/TDLib AI amallarini, pullik AI Writer serverining haqiqiy holatini va provayderlarni alohida tekshir. Mavjud translation/summarization’ni “Sado AI cloud backend tayyor” deb noto‘g‘ri taqdim etma.
- AI chat assistant, chat analysis (qarorlar/vazifalar/xulosalar), draft reply, tone/style rewrite, matnni tuzatish, image generation, voice-to-text/dictation, call summary, model/provider tanlashni parity jadvalida bahola.
- Telegram/TDLib tarjimasi bilan tashqi Google/LLM tarjimasini farqlab ko‘rsat.
- Har bir tashqi AI amali oldidan qaysi xabarlar/tarkib yuborilishini ko‘rsatib, aniq rozilik ol. Tanlangan chat tarixinigina yubor; user tanlamagan chatlarni fon rejimida skan qilma. PII redaction, retention, provayder nomi, xarajat limiti va opt-out bo‘lsin.
- AI javobi yuborilishidan oldin doim ko‘rib chiqiladigan draft bo‘lsin; avtomatik yuborish default o‘chiq.
- Nicegram voice transcription’ini Sado’dagi Telegram `RecognizeSpeech` bilan taqqosla; transkripsiya borligi microphone orqali matn kiritish bor degani emas.

### E. Maxfiylik va kontaktlar

- Hidden chats/account, chat PIN/biometrik lock, immediate auto-lock, notification preview, app-switcher privacy va session backup xavfini tekshir.
- Kontaktga local note, biznes eslatma, teg, keyingi aloqa sanasi. Mavjud chat ichidagi lokal xabar/eslatmani contact profile metadata’si bilan bir deb hisoblama.
- Contact change timeline; special-contact online/offline notifications va activity history’ni Telegram privacy settings bilan cheklab, kuzatuvni foydalanuvchi ko‘rib turgan va boshqara oladigan qilib loyihala. Privacy’ni aylanib o‘tish, yashirin presence scraping yoki API limitlarni chetlab o‘tish mumkin emas.
- “Access restricted/blocked chats” kabi da’volarni Telegram yoki OS cheklovlarini aylanib o‘tadigan tarzda implementatsiya qilma. Rasmiy API va Telegram shartlariga mos kelmasa, parity ro‘yxatida “qo‘shilmaydi — platforma/abuse/compliance riski” deb yoz.

### F. Media va qo‘ng‘iroqlar

- Downloader: progress, pause/resume/cancel, kategoriya, qidiruv, storage, original filename, parallelism va xatoni tiklash.
- Rasm yuborish sifati/compression, media albom tartibi, fayl nomi, progress, video note’ni galereyadan yaratish va asosiy kameradan yozish.
- Voice changer’ni xabar uchun va real-time qo‘ng‘iroq uchun alohida bahola; audio pipeline, latency, battery va platforma codec talablarini ko‘rsat.
- Call recording/summary bo‘lsa, platforma imkoniyati, saqlash joyi va suhbat qatnashchilariga bildirish masalasini hal qilmasdan feature’ni chiqarma.
- Sado repo’dagi 1:1/group call kodini, docs’ni va security auditni birga tekshir. E2EE tasdiqlanmagan call’ni “end-to-end encrypted” deb nomlama. Kerak bo‘lsa feature’ni cheklash yoki aniq ogohlantirishni taklif qil.

### G. Tema, UI va konfiguratsiya

- Plus: ko‘p UI elementlar rangi/o‘lchami, bubble/check dizaynlari, telefon font/emoji, navigation menu item’larini yashirish, wallpaper’dan chat ichida foydalanish.
- Tema yaratish, saqlash, import/export va share; Sado setting backup/restore.
- Sado’dagi dark/light/accent/font/bubble sizing bilan taqqosla. Har bir theme contrast, dynamic text, screen reader va small screen’da tekshir.
- Til sonini “raqibda ko‘p” deb avtomatik oshirma: avval Sado’dagi Uzbek/Russian/English tarjimalari to‘liqligi va UI overflow’ni tekshir.

## ARXITEKTURA QOIDALARI

- Sado mustaqil Telegram backend emas: TDLib Telegram bilan ishlaydi. Sado backend’iga Telegram session yoki xabar matnini qo‘shma, agar maxsus security/privacy design, aniq rozilik va alohida talab bo‘lmasa.
- Hozirgi Flutter + TDLib + Riverpod tuzilmasini tushunmasdan almashtirma. Funksiyalarni feature modul, state/controller, repository/service va UI qatlamlariga mos, kichik o‘zgarishlar bilan qo‘sh.
- TDLib update’larini yagona haqiqat manbai sifatida ishlat; chat/message list’ni o‘zboshimchalik bilan dublikat server keshiga ko‘chirma.
- Bir xil amallarni takror yuborish, offline/online holat, TDLib error/FLOOD_WAIT, akkaunt almashinuvi va ilova qayta ishga tushishini handle qil.
- AI/provider, session backup yoki auto-reply uchun yangi backend zarur bo‘lsa, avval threat model va data-flow’ni hujjatlashtir; modular monolith’ni microservice’lara bo‘lib yuborma.
- Android/iOS farqlarini aniq tut. Faqat bir platformada ishlaydigan imkoniyat UI’da boshqasida mavjud deb ko‘rinmasin.
- “Unlimited” kabi marketing sonlarini kod limiti bilan chalkashtirma; xotira/parallel client testlariga tayangan amaliy limit belgila.

## ISH BOSQICHLARI

### 0. Boshlang‘ich holatni asrash

- Git status va user o‘zgarishlarini yozib ol; mavjud diff/untracked fayllarni saqla.
- Repo qoidalari, ishga tushirish/format/lint/test komandalarini aniqlab ol.
- Avvalgi audit hujjatlarini o‘qi; security issue’larni yo‘qotma.

### 1. Feature parity auditi

- `docs/feature-parity-audit.md` yarating: feature, raqib(lar), source URL/platform, Sado statusi, dalil fayllar, risk, dependency, acceptance criteria, taxminiy effort (S/M/L), priority (P0–P3).
- Bir funksiyani faqat reklama sahifasidan ko‘rib Sado’da yo‘q deb belgilama; real kod oqimini ko‘r.
- Sado’da mavjud bo‘lsa, uni qayta yaratish o‘rniga aniqlangan kamchilikni yoz.
- Raqib manbalarini 2026-10-30 holatida tekshir; agar sahifa ko‘rinmasa, buni qayd et.

### 2. Xavf va ustuvorlik

Quyidagi tartibni boshlang‘ich mezon sifatida ishlat, lekin audit dalili bilan o‘zgartir:

- **P0 — ishonch/xavfsizlik:** qo‘ng‘iroq E2EE holati; TDLib secure storage fail-closed; notification/app-switcher privacy; sessiya backup threat model; AI data-flow/consent; README va kod zidliklari.
- **P1 — kundalik asos:** akkaunt menejeri va xavfsiz ko‘chirish; custom tabs/categories/quick links; forward tahriri; downloader; contact notes; backup/restore sozlamalari.
- **P2 — kuchli farqlovchi:** Timeline/Hashtags+; AI chat analysis va draft reply; outgoing translate/dictation; Auto Answer; Link Extractor.
- **P3 — maxsus/ko‘proq risk:** voice changer; contact online tracking; AI image generation/agent marketplace; katta akkaunt limitlari. Har biriga privacy, performance, monetization va platforma tahlili shart.

Har bir phase uchun kichik scope, dependency va qaytarib olish mumkin bo‘lgan release bosqichlarini belgila. Butun ilovani bir katta diff’da qayta yozma.

### 3. Amalga oshirish

- Avval P0’dagi aniq, repo ichida tuzatiladigan muammolarni hal qil.
- Keyin eng yuqori qiymatli, xavfi nazorat qilinadigan P1 funksiyalarni birma-bir implementatsiya qil.
- Har feature uchun UI state’lari: loading, empty, error, offline, permission denied, retry, success va destructive confirm holatlari bo‘lsin.
- Accessibility (semantics, TalkBack/VoiceOver, dynamic text), localized strings (uz/ru/en) va dark/light theme’ni kirit.
- Eski preference/database bilan backward compatibility saqla; migration kerak bo‘lsa idempotent yoz.
- API/TDLib qo‘llamaydigan ishni soxta UI bilan ko‘rsatma. “Unsupported” holatini tushunarli ko‘rsat.

### 4. Sifat nazorati

- Loyiha belgilagan format/lint/analyze va tegishli testlarni bajar; yangi state, persistence, parsers va xatolar uchun test qo‘sh.
- Android/iOS build imkon bo‘lsa tekshir. Build tool yoki native dependency mavjud bo‘lmasa, aniq qayd et.
- Secret, API key, user session, chat matni logga chiqmasligini tekshir.
- Performance: ko‘p chat/akkaunt, katta media ro‘yxati, pagination, isolate va memory pressure’ni hisobga ol.
- Testni o‘chirib yoki zaiflashtirib “yashil” qildirma.

## QAT’IY CHEKLOVLAR

- Raqobatchi ilovaning source, brending, grafik asset, matn yoki yopiq API’sini ko‘chirma. Faqat umumiy mahsulot funksiyasi va ochiq hujjatdan foydalan.
- Telegram API/TOS, privacy, user consent, App Store/Play qoidalari yoki OS permission’larini chetlab o‘tma.
- AI’ga chatlarni roziliksiz yuborma; xabarni avtomatik tahlil qilish default o‘chiq bo‘lsin.
- User session/token’ni log, analytics, crash report yoki backend’ga tasodifan uzatma.
- Ishlamagan funksiyani tayyor deb ko‘rsatma; beta, platforma cheklovi, pullik/region cheklovini UI va report’da ayt.
- Billing/payment default’larini, signing key, release workflow yoki production deployment’i user talabisiz o‘zgartirma.
- Git reset/clean yoki user fayllarini o‘chiruvchi komandalarni ishlatma.

## YAKUNIY NATIJA

Ish tugaganda o‘zbekcha hisobot ber:

1. Qaysi competitor funksiyalari Sado’da oldindan bor edi.
2. Qaysi funksiyalar qisman bor edi va qanday yaxshilandi.
3. Yangi qo‘shilgan funksiyalar va tegishli fayllar.
4. Hozircha qo‘shilmaganlar, sabab va keyingi aniq qadam.
5. Xavfsizlik/privacy qarorlari, platforma cheklovlari va ochiq risklar.
6. Qaysi analyze/test/build komandalar ishlatildi va natijasi.
7. `docs/feature-parity-audit.md` va boshqa hujjat havolalari.

Avval repo va manbalarni tekshir; audit jadvalini tuz; keyin implementatsiyani boshlagin. Faqat juda muhim qaror foydalanuvchi afzalligiga bog‘liq bo‘lsa savol ber. Oddiy arxitektura tanlovlarini xavfsiz default bilan mustaqil hal qil.

---
