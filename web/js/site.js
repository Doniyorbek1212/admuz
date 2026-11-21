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

  // Wallet page: sign in through the pay bot (one-time code), then show the balance and open Payme for a pack.
  // The session token lives in sessionStorage only: it dies with the tab and the server expires it in 30 minutes.
  function wireWallet() {
    const box = document.getElementById("wallet");
    if (!box) return;
    const SESSION_KEY = "uzaro.wallet";
    const POLL_MS = 2000;
    const status = box.querySelector("#wallet-status");
    const bot = box.querySelector("#wallet-bot");
    let poll = 0;
    const message = (key, name = "") => {
      const template = box.querySelector(`#wallet-messages [data-msg="${key}"]`) || box.querySelector('#wallet-messages [data-msg="error"]');
      return template.textContent.replace("{name}", name);
    };
    const say = (text = "") => { status.textContent = text; };
    const step = (name) => box.querySelectorAll("[data-step]").forEach((el) => { el.hidden = el.dataset.step !== name; });
    const token = {
      get() { try { return sessionStorage.getItem(SESSION_KEY); } catch { return null; } },
      set(value) { try { sessionStorage.setItem(SESSION_KEY, value); } catch { /* not remembered: sign in again next time */ } },
      clear() { try { sessionStorage.removeItem(SESSION_KEY); } catch { /* nothing stored */ } },
    };
    const api = async (path, options = {}) => {
      const headers = { Accept: "application/json", ...(options.body ? { "Content-Type": "application/json" } : {}) };
      const session = token.get();
      if (session) headers["X-Wallet-Session"] = session;
      const response = await fetch(path, { ...options, headers, cache: "no-store" });
      const data = response.status === 204 ? null : await response.json().catch(() => null);
      return { status: response.status, data };
    };
    const failure = (code) => (code === 429 ? "busy" : code === 503 ? "off" : "error");
    const stopPolling = () => { clearTimeout(poll); poll = 0; };
    const signOut = (text = "") => { stopPolling(); token.clear(); step("out"); say(text); };

    async function showWallet() {
      const { status: code, data } = await api("/v1/web/wallet");
      if (code === 401) return signOut();
      if (code !== 200 || !data) return say(message(failure(code)));
      box.querySelector("#wallet-name").textContent = message("hello", String(data.name || "").slice(0, 64));
      box.querySelector("#wallet-balance").textContent = String(data.balance_text || "");
      const packs = box.querySelector("#wallet-packs");
      packs.replaceChildren(...(Array.isArray(data.packs) ? data.packs : []).map((pack) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "btn btn-main";
        button.textContent = String(pack.text || "");
        button.disabled = !data.payme;
        button.addEventListener("click", () => openPayme(Number(pack.amount_uzs), button));
        return button;
      }));
      step("in");
      say(data.payme ? "" : message("payme_off"));
    }

    async function openPayme(amount, button) {
      button.disabled = true;
      try {
        const { status: code, data } = await api("/v1/web/payme", { method: "POST", body: JSON.stringify({ amount_uzs: amount }) });
        if (code === 401) return signOut(message("expired"));
        const url = data && typeof data.checkout_url === "string" ? data.checkout_url : "";
        // Only Payme's own checkout is followed, whatever the answer says.
        if (code !== 201 || !/^https:\/\/(checkout|test)\.paycom\.uz\//.test(url)) return say(message(failure(code)));
        location.href = url;
      } catch {
        say(message("error"));
      } finally {
        button.disabled = false;
      }
    }

    async function waitForBot(code, deadline) {
      if (Date.now() > deadline) return signOut(message("expired"));
      try {
        const { status: answer, data } = await api(`/v1/web/login/${encodeURIComponent(code)}`);
        if (answer === 404) return signOut(message("expired"));
        if (answer === 200 && data?.status === "ok" && typeof data.token === "string") {
          stopPolling();
          token.set(data.token);
          say();
          return showWallet();
        }
      } catch {
        // A dropped request is retried on the next tick.
      }
      poll = setTimeout(() => waitForBot(code, deadline), POLL_MS);
    }

    box.querySelector("#wallet-login").addEventListener("click", async (event) => {
      const button = event.currentTarget;
      button.disabled = true;
      say();
      try {
        const { status: code, data } = await api("/v1/web/login", { method: "POST" });
        const link = data && typeof data.bot_url === "string" && /^https:\/\/t\.me\/[A-Za-z0-9_]{5,32}\?start=web_[\w-]+$/.test(data.bot_url) ? data.bot_url : "";
        if (code !== 200 || !link) return say(message(failure(code)));
        bot.href = link;
        step("wait");
        bot.focus();
        waitForBot(data.code, Date.now() + (Number(data.expires_in) || 600) * 1000);
      } catch {
        say(message("error"));
      } finally {
        button.disabled = false;
      }
    });
    box.querySelector("[data-wallet-cancel]").addEventListener("click", () => signOut());
    box.querySelector("#wallet-logout").addEventListener("click", async () => {
      await api("/v1/web/logout", { method: "POST" }).catch(() => null);
      signOut();
    });

    // Coming back from Payme or a new visit in the same tab: the session is still there.
    if (token.get()) showWallet().catch(() => say(message("error")));
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
  wireWallet();
  loadRelease();
})();
