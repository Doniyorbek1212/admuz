# Sado — raqobatchilar bilan funksional parity auditi

**Tekshiruv sanasi:** 2026-10-30  
**Qamrov:** foydalanuvchi bergan AyuGram, Plus Messenger, Nicegram, aka Messenger va Graph Messenger manbalari; Sado Flutter/TDLib kodi, README va mavjud xavfsizlik auditi.  
**Maqsad:** hozirgi holatni va farqlarni aniqlash, qo‘shish ishlarini qiymat/xavf bo‘yicha tartiblash. Bu kod review va ommaviy mahsulot sahifalari tahlili; real qurilmada feature QA, store release tekshiruvi yoki xavfsizlik sertifikatsiyasi emas.

## Qisqa xulosa

Sado oddiy Telegram klienti darajasidan ancha o‘tgan: 5 ta akkaunt, chat turlari bo‘yicha tablar, ghost mode, lokal o‘chirilgan/tahrirlangan xabar arxivi, yashirin chatlar, PIN bilan app lock, Telegram AI amallari, yuklanmalar boshqaruvi, kontakt o‘zgarishlari, business quick replies, chizma va sticker yaratish, ko‘plab Telegram boshqaruvlari mavjud. Bir qator raqib afzalliklari Sado’da allaqachon qisman yoki to‘liq qoplangan.

Eng foydali qo‘shimchalar: **kontaktga lokal qaydlar**, **akkauntlar uchun qidiriladigan boshqaruv va xavfsiz ko‘chirish/backup**, **sozlamalar/theme export-import**, **custom tablar va lokal kategoriyalar**, **xabar havolalarini ajratib olish**, **chatlararo timeline**, **chatdan kontekst tanlab AI xulosa va reply draft**. Eng avval P0 ishonch masalalari hal qilinishi kerak: call xavfsizligi va release holati, mahalliy maxfiy arxivlarning himoyasi, secure storage fallback’i, privacy UX hamda hujjat-kod ziddiyatlari.

**Muhim:** siz yuborgan `ayugramsapk.com` sahifasi AyuGram’ning rasmiy loyihasi emas, reklama/SEO matni va aloqasiz tashqi havolalar bilan to‘ldirilgan. AyuGram imkoniyatlari uchun rasmiy loyiha hujjatlari va GitHub tavsifi ishlatildi. Graph’ning `/uz` bosh sahifasi ochilmadi, ammo rasmiy `/uz/features` sahifasi o‘qildi. aka bosh sahifasi indekslanmagan; Google Play/App Store va aka’ning rasmiy Telegram kanalidan foydalanildi. Saytlardagi marketing da’volari real build’da mavjudligini mustaqil tasdiqlamaydi.

## Holat belgilari

- **MAVJUD** — UI va ishlaydigan state/Telegram amali aniqlangan.
- **QISMAN** — asosiy imkoniyat bor, lekin raqibdagi to‘liq oqim yoki qulayliklar yetishmaydi.
- **FAQAT API/STATE** — model yoki TDLib amali topilgan, to‘liq foydalanuvchi oqimi tasdiqlanmadi.
- **TOPILMADI** — ko‘rilgan kodda imkoniyat aniqlanmadi.
- **TEKSHIRISH KERAK** — kod, README, platforma yoki xavfsizlik holati ziddiyatli; real qurilmada tasdiqlanishi zarur.

## Parity jadvali

| Imkoniyat | Raqib dalili | Sado holati va dalil | Farq / tavsiya | Ustuvorlik |
|---|---|---|---|---|
| Ko‘p akkaunt va tez almashish | Nicegram iOS 1000, Android 100; aka tavsifi 6; Graph yashirin akkauntlar | **MAVJUD:** `mobile/lib/state/providers.dart` limiti 5; `home_drawer.dart` switcher | 5 ta mantiqiy limit. Label va switch bor, lekin akkaunt qidiruvi/rangli identifikatsiya va kengaytirilgan managerni tekshirish kerak. Raqibdagi “1000”ni ko‘chirmang; TDLib klientlari, RAM, batareya va tarmoq xarajatini hisoblang. | P1 |
| Akkauntni yangi qurilmaga ko‘chirish | Nicegram session export/import, iCloud backup | **TOPILMADI:** session export/import yoki encrypted backup oqimi topilmadi. TDLib DB alohida akkaunt kataloglarida | Qurilma almashtirishda qayta login kerak. Avval threat model; export qilinadigan sessiya credential darajasidagi sir. Parol bilan shifrlash, biometric/PIN, qisqa muddatli fayl, importdan keyin faylni o‘chirish va revoke UX kerak. | P1 |
| Hidden account / Double Bottom | Nicegram ikki passcode orqali akkaunt ko‘rinishini o‘zgartiradi | **QISMAN:** `settings.dart`, `home_drawer.dart`, `app_lock.dart` — yashirin chatlar, app PIN | Yashirin chat bor, alohida yashirin akkaunt rejimi topilmadi. Notification/search/switcher/app-switcher izlari va PIN reset UX’ini audit qiling. PIN alohida biometrik emas. | P2 |
| Chat turlari bo‘yicha tablar | Plus, aka va Graph tab/filterlarni ta’kidlaydi | **MAVJUD:** `settings.dart` chatTypeTabs; home oqimi | README bo‘yicha users/groups/channels/bots/unread. Foydalanuvchi tablarni yashirish, qayta tartiblash, own filters yoki favorites/admin bo‘yicha tab yaratishi tasdiqlanmadi. | P1 |
| Papka/kategoriya va custom navigation | Plus customization; Graph custom menu/recent chats panel | **QISMAN:** Telegram-sinxron folderlar va lokal chat-type tabs mavjud; `folders_screen.dart` | Lokal kategoriyalar, tab tartibi/visibility, quick links va chat ichida recent-chat switcher topilmadi. Telegram folderlarini app-local kategoriyalar bilan chalkashtirmasdan qo‘shing. | P1 |
| Kanal Timeline va Hashtags+ | Graph bir nechta kanal xabarini bitta feed’da ko‘rsatishni reklama qiladi | **TOPILMADI:** unified feed ko‘rinmadi; hashtag qidiruvi/suggestion bor | Ixtiyoriy manba tanlash, pagination, kanalga qaytish va read/unread hisobini o‘zgartirmaslik bilan feed kerak. | P2 |
| Bulk amallar va ko‘p chatga yuborish | Graph multi-send va batch forward | **QISMAN:** chat ro‘yxatidan yakka amallar, multi-message forward mavjud | Bir vaqtda bir nechta chatga jo‘natish, natija/failed-chat holatlari hamda chat-list bulk read/mute/archive oqimlari topilmadi. Anti-spam va rate-limit UX bilan bosqichma-bosqich qiling. | P2 |
| Moslashuvchan forward | aka va Graph editable forward; Sado advanced forward | **MAVJUD/QISMAN:** `forward_picker.dart`, `chat_screen.dart`; hide sender/caption va bitta text uchun edit | Asosiy “advanced forward” mavjud. Bir nechta xabar matnini o‘zgartirish, find/replace, prefix/suffix qo‘shish, tartiblash va albom elementlarini alohida boshqarish cheklangan. | P1 |
| Link extractor | Graph xabaraas URL/username/email/phone/hashtag ajratadi | **TOPILMADI:** link rendering/safety bor (`link_safety.dart`), extraction workflow topilmadi | Bitta xabar yoki tanlangan xabarlardan turlarga bo‘lingan havola/username/telefon/email ro‘yxati va nusxa olish. Link safety tekshiruvini chetlab o‘tmasin. | P2 |
| Quick replies / shablonlar | Nicegram quick replies; Graph auto/bulk amallar | **MAVJUD, lekin Telegram Business doirasida:** `business_quick_replies.dart`, `composer.dart` | Telegram Business quick replies va greeting/away ko‘rinadi; generic barcha foydalanuvchilar uchun lokal templates yo‘q. Shortcut search va sozlamalarni export qilishni qo‘shish foydali. | P1 |
| Auto-reply | Graph/Business uslubidagi avtomatlashtirish | **QISMAN:** Telegram Business greeting/away amallari `business_settings.dart`da | Bu Telegram server tomonidagi Business qoidalari; custom trigger/allowlist auto-reply topilmadi. Backgroundda app ishlashi yoki user session serverga ko‘chirilishini talab qiladigan yechim qilinmasin. | P2 |
| Ghost mode | AyuGram ghost mode; Sado ghost rejimi | **MAVJUD, Telegram cheklovlariga bog‘liq:** `settings.dart`, `app.dart` | Read receipt/typing bostiriladi. Online holatni mutlaq yashirish yoki story ko‘rish izini yo‘qotish server cheklovlarida kafolatlanmaydi. UX’da aynan qaysi signal bostirilishi va qaysi amal sizni online ko‘rsatishi tushuntirilsin. | P0 sifat/ishonch |
| Deleted/edit history, message filters | Rasmiy AyuGram docs: lokal tarix, message filters; Sado README | **MAVJUD, maxfiylik xatari bor:** `state/message_archive.dart`, `chat_history.dart`; sozlamada keepDeleted/keepEditHistory | Lokal nusxa chatdan o‘chirilgan bo‘lsa ham qurilmada saqlanadi. Aniq opt-in, retention/clear, export/backup siyosati va shifrlash kerak. Blocked users/ads message filter parity alohida tekshirilishi zarur. | P0 |
| AI xabar xulosasi, tarjima, yozuvni yaxshilash | Nicegram Lily AI, in-chat summary/reply; Graph AI tools | **MAVJUD, ammo Telegram/TDLib AI:** `state/actions.dart`, `composer.dart`, `chat_screen.dart`; server docs AI Writer’ni alohida ko‘rsatadi | Telegramning `TranslateText`, `SummarizeMessage`, `ComposeRichMessageWithAi` amallari tashqi Sado AI backend degani emas. Multi-message chat analysis, qaror/action item va source-message jump, contextga mos reply draft, model/provider setting topilmadi. | P1/P2 |
| Ovozdan matn va diktovka | Nicegram voice transcription va speech dictation | **QISMAN:** `RecognizeSpeech` orqali Telegram voice xabarini transkripsiya qilish; `misc_extras.dart` feedback | Voice-note transkripsiyasi bor; keyboard mikrofonidan matn diktovkasi va transkripsiyani AI tahrirlash topilmadi. Til/platforma/Premium shartlari Telegram tomonidan belgilanadi. | P2 |
| AI assistant/image/agent marketplace/call summary | Nicegram bu imkoniyatlarni ayrim planlarda ko‘rsatadi | **TOPILMADI** | Yangi cloud AI bo‘lsa xabar faqat user tanlagan, consent bilan; provider, retention, narx, opt-out va draft-only yuborishni loyiha qiling. Call recording/summary qonun va OS cheklovlariga bog‘liq. | P3 (AI chat analysis P2) |
| Lokal kontakt qaydlari / teglari | Nicegram user notes | **TOPILMADI**: kontakt o‘zgarishlari logi bor, lekin profilga shaxsiy qayd/teg yo‘q | Faqat qurilmada saqlanadigan notes, qidiruv va backup siyosati bilan qo‘shish. Notes Telegram’ga sinxronlanmasligini ko‘rsating. | P1 |
| Kontakt o‘zgarishlari | Graph contact change timeline | **MAVJUD:** `state/contact_changes.dart`, `settings/uzaro_tools.dart` | Rasm, telefon, ism, username snapshotlari TDLib update kelganda yoziladi. Faqat ko‘rilgan kontakt update’lari; “hamma o‘zgarishni real vaqtda kuzatadi” deb va’da bermang. JSON lokal faylining shifrlanmaganligi security auditda qayd etilgan. | P0/P1 |
| Maxsus kontakt online alert/activity tracker | Graph presence alert/history | **TOPILMADI** | Yashirin presence scraping qo‘shilmasin. Faqat Telegram ruxsat bergan `UserStatus` update, user tanlovi, ko‘rinadigan boshqaruv va qat’iy rate limit bo‘lsa keyin baholang. | P3/riskli |
| Yuklanmalar menejeri | Graph/aka pause/resume manager | **MAVJUD:** `features/settings/downloads_screen.dart`; TDLib pause/resume/cancel, progress | Asosiy manager bor. Kategoriya, filter/search, queue parallelism boshqaruvi, xatodan tiklash va storage joyi bilan to‘liq paritet aniqlanmagan. Original nom bilan share/open yordamchisi bor. | P1 yaxshilash |
| Rasm chizish va sticker yaratish | Graph draw-to-sticker | **MAVJUD/QISMAN:** `photo_draw_screen.dart`, `sticker_creator.dart` | Rasm ustiga chizish va Telegram sticker set yaratish kodi bor. Chizmani mustaqil sticker sifatida eksport qilish oqimi alohida UI ko‘rigini talab qiladi. | P2 polish |
| Voice changer | Graph real-time voice effect claim | **TOPILMADI** | Audio processing, codec, kechikish, call pipeline va app store qoidalari bo‘yicha xavf bor. Avval opt-in voice message prototipini baholang; real-time call o‘zgartirishni P3’dan oldin boshlamang. | P3 |
| Call recording | Nicegram iOS call recording, aka voice/video calls | **TEKSHIRISH KERAK:** call UI/native stack folders mavjud; real 1:1/group E2EE va production-ready status tasdiqlanmagan | Kodda `calls/` stack va video chat recording-control namunalari bor, ammo README “qo‘ng‘iroqlar yo‘q” deydi. `docs/security-audit.md` konferensiya E2EE’ni tasdiqlanmagan/high concern deydi. Call state, Android/iOS build, Telegram interop va kripto tekshiruvisiz qo‘llab-quvvatlanadi deb e’lon qilmang; group call’ni cheklash yoki aniq xavfsizlik ogohlantirishi kerak. | P0 |
| App lock, chat lock, screenshot/privacy | Nicegram Double Bottom; Graph pattern and per-chat lock | **QISMAN:** `core/app_lock.dart` PIN/autolock; hidden chats PIN gate; app notification preview suppresses (`app.dart`) | PIN va yashirin chat bor, lekin biometric/pattern, chat uchun alohida lock, app switcher snapshot blur va Android screenshot prevention to‘liq tasdiqlanmagan. `app_lock.dart` va native lifecycle’ni release qurilmada tekshirish. | P0 |
| UI customizatsiyasi / tema almashish | Plus rang/o‘lcham/theme share; AyuGram custom fonts | **QISMAN:** 7 accent, dark/light/system, font family, text scale, bubble radius, wallpaper | Custom theme create/import/share, keng UI tokenlar, tab/menu re-order va cross-device settings backup topilmadi. Contrast/accessibility va localization ham parity mezoni bo‘lsin. | P1 |
| In-app utilities/browser/QR/games | Graph in-app browser, QR, mini games | **QISMAN:** QR scanner va Telegram WebApp/browser mavjud | Telegram WebApp browser alohida ilova ichidagi umumiy link browser degani emas; mini games katalogi topilmadi. In-app browser xavfsizlik sanitizatsiyasi/link safety bilan integratsiya qilinsin. | P2/P3 |
| Til qamrovi | Graph 12 til deb e’lon qiladi | **TOPILMADI / hozircha 3 til:** README/l10n uz, ru, en | Sifatli localization va UI overflow muhim; tarjima to‘liqligi audit qilinmasdan raqamni oshirmang. Uzbek tajribasi Sado’ning ajralib turuvchi ustunligi. | P2 |
| Plus mayda customization: original filename, video compression, phone emoji, mute/add from home | Plus rasmiy sahifasi | **QISMAN/TEKSHIRISH KERAK** | Sado’da tema, wallpaper, sound, font, avatar/profile sozlamalari bor. Video compression sifat darajalari va home’dan mute/add shortcuts’ni aniq oqim sifatida tekshirish kerak. | P2 |

## Raqiblar bo‘yicha qaydlar

### AyuGram

Yuborilgan `ayugramsapk.com` rasmiy manba sifatida qabul qilinmadi: sahifada ko‘p aloqasiz kazino/app download havolalari bor, matn ichida versiya raqami ham zid. Rasmiy AyuGram hujjatlari Android va desktop build’larini ajratadi. Ular ghost mode, local message history/anti-recall, message filters, local Premium va restricted-forwarding kabi ba’zi imkoniyatlarni sanaydi; loyiha o‘zi ayrimlari Telegram qoidalarini buzishi mumkinligini bildiradi. Sado faqat foydalanuvchi nazoratidagi lokal arxivni shaffof saqlashi mumkin; cheklangan forward, secret/self-destruct content’ni yashirin saqlash yoki skrinshot ogohlantirishini o‘chirishni parity talabi sifatida qabul qilmaslik kerak.

### Plus Messenger

Rasmiy sahifa customization’ni asosiy farq sifatida ko‘rsatadi: ko‘p rang/o‘lcham, o‘z tema yaratish/saqlash/ulashish, telefon font/emoji, original file name, video compression, chat wallpaper, main list’dan mute va member qo‘shish. Sado ko‘rinish sozlamalarida yaxshi poydevorga ega; theme preset import/export va nozik UI control’lar asosiy farq bo‘lib qolmoqda.

### Nicegram

Bugungi feature sahifasida multi-account va backup, Lily AI, chat summary, reply draft, speech-to-text, translator, Double Bottom, hidden chats, keyword folders, contact notes, quick replies va boshqalar keltirilgan. Bir qismi Premium/AI token, bir qismi iOS/platformaga bog‘liq. Sado’dagi AI amallarini provider, data path, account credentials saqlash va AI roziligi bo‘yicha alohida baholash kerak; `docs/monetization/README.md` Telegram AI hamda Sado AI Writer backend’ini alohida ko‘rsatadi.

### aka Messenger

Google Play/App Store tavsiflarida voice/video call, secret chat, tab filter va bir nechta akkaunt tilga olinadi. Rasmiy Telegram kanaldagi eski release postlari deleted/edit history, advanced forward, translation, downloader va custom themes kabi funksiyalar oldingi versiyalarda bo‘lganini ko‘rsatadi, ammo eski release notes 2026 build uchun kafolat emas. Sado’dagi calls hujjatlari va real qurilma parity’sini alohida tekshirish kerak.

### Graph Messenger

Ochiq `/uz/features` sahifasida AI, downloader, hidden accounts, voice changer, custom menu, recent chat panel, built-in browser/QR/game, pattern lock, bot-account login, timeline/hashtags+, favorites, custom/multi-send, link extractor, draw/sticker maker va contact tracking sanaladi. Bu ishlab chiquvchining marketing da’volari; ularni Sado’ga avtomatik ko‘chirish shart emas. Bot-token login, cheklanmagan kuzatuv va voice changer’da abuse/privacy/security xavfi yuqori.

## “To‘liq tayyor” deb aytishdan oldin hal qilinadigan P0

1. **Qo‘ng‘iroq xavfsizligi va roadmap:** `README.md` calls yo‘q deydi, lekin `mobile/lib/features/calls/` va `mobile/lib/core/calls/` implementatsiyasi bor. `docs/security-audit.md` conference E2EE tasdiqlanmaganini aytadi. Release scope’ni belgilang, risky group calls’ni cheklang yoki xavfni qo‘ng‘iroq oldidan aniq ko‘rsating. 1:1 va conference’ni alohida tekshiring.
2. **Lokal maxfiy nusxalar:** deleted/edit history va contact-change snapshotlari JSON/local storage’da. Qaysi ma’lumot qancha saqlanishi, clear/export, local encryption va app lock bilan bog‘lanishi kerak.
3. **Secure storage fallback:** mavjud audit secure storage xatosida himoyasi past fallback borligini qayd etadi. Auth key/database key hech qachon ochiq faylga yozilmasin; fail-closed yoki foydalanuvchiga aniq qayta autentifikatsiya yo‘li.
4. **Privacy UX:** ghost rejim Telegram server cheklovlariga bo‘ysunadi. Skrinshotni bloklash OS/App Store cheklovlarini bekor qilmaydi. Hidden chat oddiy UI’dan yashirilishini, lekin qurilma forensikasidan himoya qilmasligini aniq ayting.
5. **Data flow va marketing:** TDLib orqali bajariladigan Telegram AI amallarini Sado AI cloud deb atamang; tashqi AI’ga chat yuborishda aniq rozilik, data-flow, narx va saqlash muddati kerak.

## Amalga oshirish tartibi

| Bosqich | Ishlar | Qabul mezoni |
|---|---|---|
| 0 — Ishonch (P0) | call code/security scope; secure storage fallback; archive/contact JSON encryption va retention; notification/app switcher privacy; README/docs muvofiqligi | Real Android va iOS qurilmada auth, lock, notification, background/recents, calls oqimi tekshirilgan; E2EE bo‘yicha asossiz va’da yo‘q; ma’lumot qanday saqlanishi yozilgan |
| 1 — Kundalik farq (P1) | account manager va encrypted transfer design; contact notes; tab/custom categories/quick links; theme va settings backup; advanced forward polishing; downloader queue/search | Offline/error/restore flow; session secrets parol bilan protected, import/export o‘zaro ishlaydi; lokal sozlamalar Telegram serveriga chiqmaydi |
| 2 — Ish samaradorligi (P2) | link extractor; multi-select/multi-send; custom timeline; AI chat analysis + source links/reply drafts; dictate; tab personalization; in-app browser polish | Asl xabarlarga qaytish mumkin; AI javobini foydalanuvchi tasdiqlaydi; pagination/read state to‘g‘ri; localization/accessibility tekshirilgan |
| 3 — Tajriba funksiyalari (P3) | AI agents/image; voice changer; ruxsat etilgan doiradagi presence alert; mini tools/games; keyinchalik akkaunt limitini qayta ko‘rish | Platform/API/ToS/privacy review, resource budget va opt-in hujjatli; performance/security tekshiruvidan keyin chiqariladi |

Bu tartib mahsulot ishonchliligini birinchi o‘ringa qo‘yadi. P1 bo‘yicha xavfi past, foydasi yuqori ishlar: account manager, lokal contact notes, theme/settings export va tab customization. P2/P3’ni boshlashdan oldin mahsulot doirasi va ma’lumot oqimini aniqlang.

## Amalga oshirish uchun qabul mezonlari

- **Account backup:** eksport faylini murakkab passphrase bilan shifrlash; Telegram/TDLib auth state plaintext saqlanmasligi; filename/log/crash report’da secret chiqmasligi; import overwrite/duplicate’ni tushuntirishi va cancel/error holatlari bo‘lishi.
- **Local contact notes:** qurilmaga xos saqlash ko‘rsatkichi; edit/search/delete; export alohida opt-in; akkaunt/kontakt doirasi; app data reset oqibati va lock/backup siyosati tushuntiriladi.
- **Custom tabs:** ko‘rsatish/yashirish, tartiblash, icon/title va filter mezonlari; qayta ochilganda saqlanadi; empty state hamda unread badge manbasi aniq.
- **Timeline:** tanlangan chat/kanallar, yangi xabardan boshlangan pagination, manba chat/xabarga deep link; timeline scroll chat unread/read holatini o‘zgartirmaydi.
- **AI analysis:** foydalanuvchi chat/xabar oralig‘ini tanlaydi; yuborishdan oldin data preview va rozilik; summary/decision/action/reply turlari; manba xabarga havola; AI javobi draft bo‘lib ko‘rinadi va avtomatik yuborilmaydi.
- **Link extractor:** entity + plain text URLs; URL safety badge; төрөл тус бүрээр copy; татах/нээх үйлдэл link safety pipeline-аар явна.
- **Settings/theme backup:** export schema/version; akkauntga tegishli va app-wide sozlamalar farqi; restore preview/merge/replace; eski yoki noto‘g‘ri versiyada rollback.

## Hujjat va kod o‘rtasidagi muhim farqlar

- README “qo‘ng‘iroqlar yo‘q” гэдэг ч кодод call screen/session байгаа. Үүнийг одоо байгаа build-д гараар шалгахгүйгээр үнэн гэж хэлж болохгүй.
- README AI-г “Telegram AI (TDLib)” гэж зөв тодорхойлсон; энэ нь AI чат бот, cloud provider, contact data-тай cloud анализ гэсэн үг биш.
- `contact_changes.dart` нь шинэ TDLib user update ирсэн үед snapshot-уудыг харьцуулдаг; апп хаалттай байсан бүх хугацаанд бодит-time tracking хийхгүй.
- `hiddenChatIds` нь local list filter болон passcode gate; Telegram account-ийг нуудаггүй. Account session export ч биш.
- Downloader-ийн үндсэн pause/resume/progress UI бий; энэ нь дэвшилтэт queue, category болон search бүрэн гэсэн үг биш.

## Foydalanilgan manbalar

### Sayt va mahsulot manbalari

- [Plus Messenger official features](https://plusmessenger.org/) — customization болон privacy-ийн тайлбар.
- [Nicegram home](https://nicegram.me/) ба [Nicegram features](https://nicegram.me/features) — AI, accounts, backup, notes, hidden chats; төлбөр ба platform нөхцөл нь сайтын дагуу.
- [Graph Messenger Uzbek features](https://www.graphmessenger.com/uz/features) — Graph-ийн одоо харагдаж буй feature claims.
- [aka Google Play listing](https://play.google.com/store/apps/details?id=org.aka.messenger), [aka App Store listing](https://apps.apple.com/us/app/aka/id1476189685), [aka official Telegram channel](https://t.me/akamessenger) — store description болон release мэдээлэл.
- [AyuGram official site](https://ayugram.io/), [AyuGram Android docs](https://docs.ayugram.one/android/), [AyuGram Ghost Mode docs](https://docs.ayugram.one/shared/ghost/) — албан ёсны project docs. `ayugramsapk.com`-ийг feature-н эрх бүхий эх сурвалж гэж ашиглаагүй.

### Kod bo‘yicha asosiy dalillar

- Account limit/state: `mobile/lib/state/providers.dart`; account switcher: `mobile/lib/features/home/home_drawer.dart`.
- Lokal settings/tabs/hidden chats: `mobile/lib/state/settings.dart`; app lock: `mobile/lib/core/app_lock.dart`.
- Ghost notifications: `mobile/lib/app.dart`; message archive: `mobile/lib/state/message_archive.dart`.
- Contacts: `mobile/lib/state/contact_changes.dart`; UI: `mobile/lib/features/settings/uzaro_tools.dart`.
- Download manager: `mobile/lib/features/settings/downloads_screen.dart`.
- Telegram AI actions: `mobile/lib/state/actions.dart`, `mobile/lib/features/chat/composer.dart`, `mobile/lib/features/chat/chat_screen.dart`.
- Advanced forward: `mobile/lib/features/chat/forward_picker.dart`.
- Drawing/sticker authoring: `mobile/lib/features/chat/photo_draw_screen.dart`, `mobile/lib/features/chat/sticker_creator.dart`.
- Calls: `mobile/lib/features/calls/`, `mobile/lib/core/calls/`; security caveat: `docs/security-audit.md`.
- Current overview/documentation: `README.md`, `docs/monetization/README.md`.

---

*Holat: audit hujjati; real qurilma qo‘ng‘iroq/notification QA va session backup threat-modeli qilinmagan. Ushbu hujjat implementatsiya yoki store compliance xulosasi emas.*
