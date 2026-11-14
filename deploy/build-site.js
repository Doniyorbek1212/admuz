// Builds the static site for uzaromessenger.uz from the Uzbek pages in web/:
//   web/ru/*.html and web/en/*.html (real per-language pages for search engines), JSON-LD,
//   cache-busting ?v= on site.css/site.js, and sitemap.xml with hreflang alternates.
// Run: node deploy/build-site.js   (no dependencies)
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");
const crypto = require("crypto");

const WEB = path.resolve(__dirname, "../web");
const BASE = "https://uzaromessenger.uz/";
const LANGS = ["uz", "ru", "en"];
const LOCALE = { uz: "uz_UZ", ru: "ru_RU", en: "en_US" };
const PAGES = ["", "docs.html", "privacy.html", "nom.html", "terms.html", "hamyon.html"]; // "" is index.html
// Public path of each page; nginx serves privacy.html at /privacy (the address the app and stores link to).
const PUBLIC = { "": "", "docs.html": "docs.html", "privacy.html": "privacy", "nom.html": "nom.html", "terms.html": "terms.html", "hamyon.html": "hamyon.html" };
// Title, description and breadcrumb name of the inner pages.
const META = {
  "docs.html": ["d_meta_title", "d_lead", "d_title"],
  "privacy.html": ["p_meta_title", "p_lead", "p_title"],
  "nom.html": ["n_meta_title", "n_lead", "n_title"],
  "terms.html": ["t_meta_title", "t_lead", "t_title"],
  "hamyon.html": ["w_meta_title", "w_lead", "w_title"],
};
const ALT_NAMES = ["Uzaro", "UZARO Messenger", "Uzaro messenjer", "Узаро", "uzaromessenger"];
// data-i18n-<suffix>="key" fills the attribute named here.
const ATTRS = { content: "content", aria: "aria-label", alt: "alt", "apk-meta": "data-apk-meta", "apk-soon": "data-apk-soon" };

const sandbox = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(WEB, "js/i18n.js"), "utf8"), sandbox);
const dict = sandbox.window.UZARO_I18N;

const url = (lang, page) => BASE + (lang === "uz" ? "" : `${lang}/`) + PUBLIC[page];
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const escAttr = (s) => esc(s).replace(/"/g, "&quot;");
const hash = (file) => crypto.createHash("sha256").update(fs.readFileSync(path.join(WEB, file))).digest("hex").slice(0, 10);

function t(lang, key) {
  const value = dict[lang] && dict[lang][key];
  if (typeof value !== "string") throw new Error(`missing translation ${lang}.${key}`);
  return value;
}

function translateText(html, lang) {
  const expected = (html.match(/\sdata-i18n="\w+"/g) || []).length;
  let done = 0;
  const out = html.replace(/(<([a-z0-9]+)\b[^>]*\sdata-i18n="(\w+)"[^>]*>)([^<]*)(<\/\2>)/g, (m, open, tag, key, text, close) => {
    done += 1;
    return open + esc(t(lang, key)) + close;
  });
  // Every data-i18n element must hold plain text only; otherwise it would silently stay Uzbek.
  if (done !== expected) throw new Error(`${lang}: translated ${done} of ${expected} data-i18n elements`);
  return out;
}

function translateAttrs(html, lang) {
  return html.replace(/<[a-z0-9]+\b[^>]*\sdata-i18n-[a-z-]+="[^"]*"[^>]*>/g, (tag) => {
    let s = tag;
    for (const [suffix, attr] of Object.entries(ATTRS)) {
      const key = s.match(new RegExp(`\\sdata-i18n-${suffix}="(\\w+)"`));
      if (!key) continue;
      const value = escAttr(t(lang, key[1]));
      const current = new RegExp(`(\\s${attr}=")[^"]*(")`);
      s = current.test(s) ? s.replace(current, `$1${value}$2`) : s.replace(/>$/, ` ${attr}="${value}">`);
    }
    return s;
  });
}

function localizeLinks(html, lang) {
  // Language-menu links (hreflang) keep their target; mark the current one.
  let out = html.replace(/<a ([^>]*\bhreflang="(\w+)"[^>]*)>/g, (m, attrs, hl) => {
    const clean = attrs.replace(/\s*aria-current="true"/, "");
    return `<a ${clean}${hl === lang ? ' aria-current="true"' : ""}>`;
  });
  if (lang === "uz") return out;
  // Links to the home page, the guide and the policy stay in the reader's language; /download is shared.
  out = out.replace(/<a\b[^>]*>/g, (a) =>
    /\shreflang=/.test(a) ? a : a.replace(/\shref="\/(#[^"]*|docs\.html[^"]*|nom\.html[^"]*|hamyon\.html[^"]*|terms\.html[^"]*|privacy)?"/, (m, rest) => ` href="/${lang}/${rest || ""}"`),
  );
  return out;
}

function jsonLd(lang, page) {
  const PLAY = "https://play.google.com/store/apps/details?id=uz.uzaro.app";
  const APPSTORE = "https://apps.apple.com/app/uzaro-messenger/id6827434122";
  const org = { "@type": "Organization", "@id": `${BASE}#org`, name: "UZARO", alternateName: ALT_NAMES, url: BASE, logo: `${BASE}assets/apple-touch-icon.png`, sameAs: [PLAY, APPSTORE] };
  const site = { "@type": "WebSite", "@id": `${BASE}#site`, name: "UZARO", alternateName: ALT_NAMES, url: BASE, inLanguage: LANGS, publisher: { "@id": `${BASE}#org` } };
  let graph;
  if (page === "") {
    graph = [
      org,
      site,
      { "@type": "WebPage", "@id": `${url(lang, "")}#page`, url: url(lang, ""), name: t(lang, "meta_title"), description: t(lang, "meta_desc"), inLanguage: lang, isPartOf: { "@id": `${BASE}#site` } },
      {
        "@type": "MobileApplication",
        name: "UZARO",
        alternateName: ALT_NAMES,
        operatingSystem: "Android, iOS, Windows",
        applicationCategory: "CommunicationApplication",
        description: t(lang, "meta_desc"),
        url: url(lang, ""),
        downloadUrl: [PLAY, APPSTORE, `${BASE}download`, `${BASE}windows/UZARO-Setup-1.1.6.exe`],
        installUrl: PLAY,
        sameAs: [PLAY, APPSTORE],
        inLanguage: LANGS,
        offers: { "@type": "Offer", price: "0", priceCurrency: "UZS" },
        publisher: { "@id": `${BASE}#org` },
        screenshot: ["home", "hub", "ai", "shop_inside"].map((n) => `${BASE}assets/screens/${n}.webp`),
      },
      {
        "@type": "FAQPage",
        inLanguage: lang,
        mainEntity: [1, 2, 3, 4, 5, 6, 7].map((i) => ({ "@type": "Question", name: t(lang, `q${i}`), acceptedAnswer: { "@type": "Answer", text: t(lang, `a${i}`) } })),
      },
    ];
  } else {
    graph = [
      org,
      site,
      {
        "@type": "WebPage",
        url: url(lang, page),
        name: t(lang, META[page][0]),
        description: t(lang, META[page][1]),
        inLanguage: lang,
        isPartOf: { "@id": `${BASE}#site` },
        breadcrumb: {
          "@type": "BreadcrumbList",
          itemListElement: [
            { "@type": "ListItem", position: 1, name: "UZARO", item: url(lang, "") },
            { "@type": "ListItem", position: 2, name: t(lang, META[page][2]), item: url(lang, page) },
          ],
        },
      },
    ];
  }
  // "<" escaped so a string can never close the script element.
  return JSON.stringify({ "@context": "https://schema.org", "@graph": graph }).replace(/</g, "\\u003c");
}

function build(template, lang, page) {
  let out = translateAttrs(translateText(template, lang), lang);
  out = localizeLinks(out, lang);
  out = out
    .replace(/<html lang="[a-z]+">/, `<html lang="${lang}">`)
    .replace(/(<link rel="canonical" href=")[^"]*/, `$1${url(lang, page)}`)
    .replace(/(<meta property="og:url" content=")[^"]*/, `$1${url(lang, page)}`)
    .replace(/(<meta property="og:locale" content=")[^"]*/, `$1${LOCALE[lang]}`)
    .replace(/<script type="application\/ld\+json" data-ld>[\s\S]*?<\/script>/, `<script type="application/ld+json" data-ld>${jsonLd(lang, page)}</script>`)
    .replace(/\/(css\/site\.css|js\/site\.js)(\?v=\w+)?"/g, (m, file) => `/${file}?v=${hash(file)}"`);
  return out;
}

function sitemap() {
  const today = new Date().toISOString().slice(0, 10);
  const entries = PAGES.flatMap((page) =>
    LANGS.map((lang) => {
      const alts = LANGS.map((a) => `    <xhtml:link rel="alternate" hreflang="${a}" href="${url(a, page)}"/>`)
        .concat(`    <xhtml:link rel="alternate" hreflang="x-default" href="${url("uz", page)}"/>`)
        .join("\n");
      return `  <url>\n    <loc>${url(lang, page)}</loc>\n    <lastmod>${today}</lastmod>\n${alts}\n  </url>`;
    }),
  );
  entries.push(`  <url>\n    <loc>${BASE}download</loc>\n  </url>`);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n${entries.join("\n")}\n</urlset>\n`;
}

for (const page of PAGES) {
  const file = page || "index.html";
  const template = fs.readFileSync(path.join(WEB, file), "utf8");
  for (const lang of LANGS) {
    const dir = lang === "uz" ? WEB : path.join(WEB, lang);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, file), build(template, lang, page));
  }
}
fs.writeFileSync(path.join(WEB, "sitemap.xml"), sitemap());
console.log(`built ${PAGES.length * LANGS.length} pages + sitemap.xml`);
