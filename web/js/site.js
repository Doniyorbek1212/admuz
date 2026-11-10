// UZARO site: language menu, scroll reveal, live APK version from the API, mobile menu.
// Every language is its own static page (/, /ru/, /en/), so this file carries no translations.
(() => {
  "use strict";

  // Fill these in when the builds are published; empty keeps the "Coming soon" button.
  const STORE_LINKS = { ios: "", windows: "" };
  const STORAGE_KEY = "uzaro.lang";
  const root = document.documentElement;
  root.classList.add("js");

  function remembered() {
    try {
      return localStorage.getItem(STORAGE_KEY);
    } catch {
      return null;
    }
  }

  function remember(lang) {
    try {
      localStorage.setItem(STORAGE_KEY, lang);
    } catch {
      // Private mode or blocked storage: the choice just isn't remembered.
    }
  }

  // A reader who picked a language before lands on it again. Nothing is guessed from the browser,
  // so search engines always get the page they asked for.
  function followSavedLanguage() {
    const saved = remembered();
    if (!saved || saved === root.lang) return false;
    const target = document.querySelector(`link[rel="alternate"][hreflang="${CSS.escape(saved)}"]`);
    if (!target) return false;
    const next = new URL(target.href);
    if (next.origin !== location.origin || next.pathname === location.pathname) return false;
    location.replace(next.pathname + location.hash);
    return true;
  }

  function wireLanguageMenu() {
    const picker = document.querySelector("details.lang");
    if (!picker) return;
    picker.querySelectorAll("a[hreflang]").forEach((a) => a.addEventListener("click", () => remember(a.hreflang)));
    const close = () => picker.removeAttribute("open");
    document.addEventListener("click", (event) => { if (!picker.contains(event.target)) close(); });
    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape" || !picker.open) return;
      close();
      picker.querySelector("summary").focus();
    });
    picker.addEventListener("toggle", () => { if (picker.open) picker.querySelector('a[aria-current="true"]')?.focus(); });
  }

  function wireReveal() {
    const items = document.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window) || matchMedia("(prefers-reduced-motion: reduce)").matches) {
      items.forEach((el) => el.classList.add("in"));
      return;
    }
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.05 });
    document.querySelectorAll(".steps .reveal").forEach((el, i) => el.style.setProperty("--d", `${i * 0.12}s`));
    items.forEach((el) => observer.observe(el));
    // At the very bottom nothing may stay hidden, whatever the screen height.
    const revealRest = () => {
      if (window.innerHeight + window.scrollY < document.documentElement.scrollHeight - 4) return;
      items.forEach((el) => el.classList.add("in"));
      window.removeEventListener("scroll", revealRest);
    };
    window.addEventListener("scroll", revealRest, { passive: true });
    revealRest();
  }

  // Same-origin API (Caddy routes /v1 to the server). Locally it is absent and the buttons keep /download.
  async function loadRelease() {
    const body = document.body;
    try {
      const response = await fetch("/v1/app/release", { cache: "no-store", headers: { Accept: "application/json" } });
      if (!response.ok) return;
      const data = await response.json();
      const url = typeof data.download_url === "string" && /^\/download\/[\w.-]+\.apk$/.test(data.download_url) ? data.download_url : null;
      const version = typeof data.version === "string" ? data.version.slice(0, 20) : "";
      const size = ((Number(data.size_bytes) || 0) / 1048576).toFixed(1);
      const available = Boolean(data.available && url && version);
      const text = available
        ? (body.dataset.apkMeta || "").replace("{version}", version).replace("{size}", size)
        : body.dataset.apkSoon || "";
      if (available) document.querySelectorAll("a[data-apk]").forEach((a) => { a.href = url; });
      // small only: <body> carries the data-apk-meta template and must never be overwritten.
      if (text) document.querySelectorAll("small[data-apk-meta]").forEach((el) => { el.textContent = text; });
    } catch {
      // Network error or non-JSON answer: the static "/download" page still works.
    }
  }

  // Short-username page: asks the API whether a name is for sale and links to the bot that sells it.
  // The messages are hidden translated templates in the page (data-msg), so this file stays language-free.
  function wireNameCheck() {
    const form = document.getElementById("name-check");
    if (!form) return;
    const input = form.querySelector("#name-input");
    const result = form.querySelector("#name-result");
    const buy = form.querySelector("#name-buy");
    const message = (key, name = "", price = "") => {
      const template = document.querySelector(`#name-messages [data-msg="${key}"]`) || document.querySelector('#name-messages [data-msg="error"]');
      return template.textContent.replace("{name}", name).replace("{price}", price);
    };
    const show = (text, ok = false, link = "") => {
      result.textContent = text;
      result.classList.toggle("ok", ok);
      buy.hidden = !link;
      if (link) buy.href = link;
    };
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const name = input.value.trim().replace(/^@/, "").toLowerCase();
      if (!/^[a-z][a-z0-9_]{1,31}$/.test(name)) return show(message("USERNAME_INVALID"));
      show("");
      try {
        const response = await fetch(`/v1/usernames/check?username=${encodeURIComponent(name)}`, { headers: { Accept: "application/json" } });
        const data = await response.json();
        if (!response.ok) return show(message(data?.detail?.code || "error"));
        const shown = typeof data.username === "string" ? data.username : name;
        const price = String(Number(data.price_uzs) || 0).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
        const bot = typeof data.bot_username === "string" && /^[A-Za-z0-9_]{5,32}$/.test(data.bot_username) ? data.bot_username : "";
        const link = data.status === "for_sale" && bot ? `https://t.me/${bot}?start=buy_${encodeURIComponent(shown)}` : "";
        show(message(data.status, shown, price), data.status === "for_sale" || data.status === "free", link);
      } catch {
        show(message("error"));
      }
    });
  }

  function wireStores() {
    document.querySelectorAll("[data-store]").forEach((el) => {
      const url = STORE_LINKS[el.dataset.store];
      if (!url) return;
      el.href = url;
      el.rel = "noopener";
      el.removeAttribute("aria-disabled");
      el.querySelector("small")?.remove();
    });
  }

  function wireMenu() {
    const button = document.querySelector(".menu-btn");
    const menu = document.getElementById("menu");
    if (!button || !menu) return;
    const toggle = (open) => {
      menu.classList.toggle("open", open);
      button.setAttribute("aria-expanded", String(open));
    };
    button.addEventListener("click", () => toggle(!menu.classList.contains("open")));
    menu.addEventListener("click", (event) => { if (event.target.closest("a")) toggle(false); });
    document.addEventListener("keydown", (event) => { if (event.key === "Escape") toggle(false); });
  }

  function wireHeader() {
    const header = document.querySelector(".top");
    if (!header) return;
    const update = () => header.classList.toggle("scrolled", window.scrollY > 8);
    window.addEventListener("scroll", update, { passive: true });
    update();
  }

  if (followSavedLanguage()) return;
  wireLanguageMenu();
  wireReveal();
  wireStores();
  wireMenu();
  wireHeader();
  wireNameCheck();
  loadRelease();
})();
