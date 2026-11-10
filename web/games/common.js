'use strict';
// Shared by every UZARO game page: language (?lang=uz|ru|en, the app passes its own), theme (?theme=light|dark),
// translated strings, and a localStorage that never throws (WebViews and private windows may block it).

const params = new URLSearchParams(location.search);
const LANG = ['uz', 'ru', 'en'].includes(params.get('lang')) ? params.get('lang') : (navigator.language || 'uz').slice(0, 2) === 'ru' ? 'ru' : 'uz';
if (['light', 'dark'].includes(params.get('theme'))) document.documentElement.dataset.theme = params.get('theme');
document.documentElement.lang = LANG;

const STRINGS = {
  uz: {
    new_game: 'Yangi oʻyin', undo: 'Orqaga', vs_ai: 'Kompyuterga qarshi', two_players: 'Ikki kishi', easy: 'Oson', medium: 'Oʻrtacha', hard: 'Qiyin',
    your_turn: 'Sizning navbatingiz', thinking: 'Kompyuter oʻylayapti…', white_turn: 'Oqlar yuradi', black_turn: 'Qoralar yuradi',
    you_won: 'Siz yutdingiz! 🎉', you_lost: 'Kompyuter yutdi', white_won: 'Oqlar yutdi! 🎉', black_won: 'Qoralar yutdi! 🎉', draw: 'Durang',
    check: 'Shoh!', must_capture: 'Urish majburiy', moves: 'Yurishlar', time: 'Vaqt', best: 'Rekord', solved: 'Yechildi! 🎉', hint: 'Yordam',
    erase: 'Oʻchirish', notes: 'Qalam', mistakes: 'Xatolar', size: 'Oʻlcham', shuffle: 'Aralashtirish', play_again: 'Yana oʻynash',
    chess: 'Shaxmat', checkers: 'Shashka', sudoku: 'Sudoku', puzzle: 'Boshqotirma', games: 'Oʻyinlar',
    chess_hint: 'Kompyuter yoki doʻst bilan', checkers_hint: 'Rus shashkasi qoidalari', sudoku_hint: '3 xil qiyinlik', puzzle_hint: 'Raqamlarni tartiblang',
  },
  ru: {
    new_game: 'Новая игра', undo: 'Отменить', vs_ai: 'Против компьютера', two_players: 'Вдвоём', easy: 'Легко', medium: 'Средне', hard: 'Сложно',
    your_turn: 'Ваш ход', thinking: 'Компьютер думает…', white_turn: 'Ход белых', black_turn: 'Ход чёрных',
    you_won: 'Вы победили! 🎉', you_lost: 'Компьютер победил', white_won: 'Белые победили! 🎉', black_won: 'Чёрные победили! 🎉', draw: 'Ничья',
    check: 'Шах!', must_capture: 'Бить обязательно', moves: 'Ходы', time: 'Время', best: 'Рекорд', solved: 'Решено! 🎉', hint: 'Подсказка',
    erase: 'Стереть', notes: 'Карандаш', mistakes: 'Ошибки', size: 'Размер', shuffle: 'Перемешать', play_again: 'Сыграть ещё',
    chess: 'Шахматы', checkers: 'Шашки', sudoku: 'Судоку', puzzle: 'Пятнашки', games: 'Игры',
    chess_hint: 'С компьютером или другом', checkers_hint: 'Русские шашки', sudoku_hint: '3 уровня сложности', puzzle_hint: 'Расставьте числа по порядку',
  },
  en: {
    new_game: 'New game', undo: 'Undo', vs_ai: 'Vs computer', two_players: 'Two players', easy: 'Easy', medium: 'Medium', hard: 'Hard',
    your_turn: 'Your move', thinking: 'Computer is thinking…', white_turn: 'White to move', black_turn: 'Black to move',
    you_won: 'You won! 🎉', you_lost: 'Computer won', white_won: 'White wins! 🎉', black_won: 'Black wins! 🎉', draw: 'Draw',
    check: 'Check!', must_capture: 'Capturing is mandatory', moves: 'Moves', time: 'Time', best: 'Best', solved: 'Solved! 🎉', hint: 'Hint',
    erase: 'Erase', notes: 'Notes', mistakes: 'Mistakes', size: 'Size', shuffle: 'Shuffle', play_again: 'Play again',
    chess: 'Chess', checkers: 'Checkers', sudoku: 'Sudoku', puzzle: 'Sliding puzzle', games: 'Games',
    chess_hint: 'Against the computer or a friend', checkers_hint: 'Russian draughts rules', sudoku_hint: '3 difficulty levels', puzzle_hint: 'Put the numbers in order',
  },
};
const t = (key) => STRINGS[LANG][key] || STRINGS.uz[key] || key;

const store = {
  get(key, fallback) { try { const v = localStorage.getItem(`uzaro.games.${key}`); return v === null ? fallback : JSON.parse(v); } catch (_) { return fallback; } },
  set(key, value) { try { localStorage.setItem(`uzaro.games.${key}`, JSON.stringify(value)); } catch (_) { /* not remembered */ } },
};

const $ = (sel) => document.querySelector(sel);
const clock = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;

/** Fills every [data-t] element with its translation and keeps ?lang/?theme on links to the other games. */
function translatePage() {
  document.querySelectorAll('[data-t]').forEach((el) => { el.textContent = t(el.dataset.t); });
  document.querySelectorAll('a[href$=".html"]').forEach((a) => { a.search = location.search; });
}

/** Seconds counter shown in [el]; start() resets, stop() freezes, value() reads. */
function makeTimer(el) {
  let started = 0; let stopped = null; let handle = 0;
  const value = () => Math.floor(((stopped ?? Date.now()) - started) / 1000);
  const show = () => { el.textContent = clock(value()); };
  return {
    start(offsetSeconds = 0) { clearInterval(handle); started = Date.now() - offsetSeconds * 1000; stopped = null; show(); handle = setInterval(show, 1000); },
    stop() { if (stopped === null) stopped = Date.now(); clearInterval(handle); show(); },
    value,
  };
}

function showDialog(text, onAgain) {
  const dialog = document.createElement('dialog');
  dialog.innerHTML = `<p style="font-size:20px;font-weight:700;margin:0 0 16px"></p><button class="btn primary" type="button"></button>`;
  dialog.querySelector('p').textContent = text;
  const button = dialog.querySelector('button');
  button.textContent = t('play_again');
  button.onclick = () => { dialog.close(); dialog.remove(); onAgain(); };
  document.body.append(dialog);
  dialog.showModal();
}
