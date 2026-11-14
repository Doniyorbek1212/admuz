'use strict';
/* global t, store, $, makeTimer, translatePage, showDialog */
// Sliding puzzle: tiles 1..n²-1 and one gap (0). Shuffled by random legal moves from the solved board,
// so every board is solvable.

let size = store.get('puzzle.size', 4);
let tiles = [];
let moves = 0;
let playing = false;
const timer = makeTimer($('#time'));

const solved = () => tiles.every((v, i) => v === (i + 1) % (size * size));

function neighbours(index) {
  const r = Math.floor(index / size); const c = index % size;
  return [[r - 1, c], [r + 1, c], [r, c - 1], [r, c + 1]]
    .filter(([y, x]) => y >= 0 && y < size && x >= 0 && x < size)
    .map(([y, x]) => y * size + x);
}

function shuffle() {
  tiles = Array.from({ length: size * size }, (_, i) => (i + 1) % (size * size));
  let gap = tiles.length - 1; let previous = -1;
  for (let i = 0; i < size * size * 40 || solved(); i++) {
    const options = neighbours(gap).filter((n) => n !== previous);
    const next = options[Math.floor(Math.random() * options.length)];
    [tiles[gap], tiles[next]] = [tiles[next], tiles[gap]];
    previous = gap; gap = next;
  }
  moves = 0; playing = true;
  timer.start();
  render();
}

/** Slides every tile between [index] and the gap when they share a row or column. */
function press(index) {
  if (!playing) return;
  const gap = tiles.indexOf(0);
  const sameRow = Math.floor(gap / size) === Math.floor(index / size);
  const sameCol = gap % size === index % size;
  if (index === gap || !(sameRow || sameCol)) return;
  const step = sameRow ? Math.sign(index - gap) : Math.sign(index - gap) * size;
  for (let at = gap; at !== index; at += step) [tiles[at], tiles[at + step]] = [tiles[at + step], tiles[at]];
  moves++;
  render();
  if (solved()) finish();
}

function finish() {
  playing = false; timer.stop();
  const best = store.get(`puzzle.best.${size}`, null);
  if (!best || moves < best.moves || (moves === best.moves && timer.value() < best.seconds)) {
    store.set(`puzzle.best.${size}`, { moves, seconds: timer.value() });
  }
  render();
  showDialog(`${t('solved')}\n${t('moves')}: ${moves}`, shuffle);
}

function render() {
  const board = $('#tiles');
  board.style.gridTemplateColumns = `repeat(${size}, 1fr)`;
  board.style.gridTemplateRows = `repeat(${size}, 1fr)`;
  board.replaceChildren(...tiles.map((v, i) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = `tile${v === 0 ? ' gap' : ''}${v !== 0 && v === i + 1 ? ' home' : ''}`;
    b.textContent = v || '';
    if (v) b.setAttribute('aria-label', String(v)); else b.tabIndex = -1;
    b.onclick = () => press(i);
    return b;
  }));
  $('#moves').textContent = moves;
  const best = store.get(`puzzle.best.${size}`, null);
  $('#best').textContent = best ? best.moves : '—';
  document.querySelectorAll('[data-size]').forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.size) === size)));
}

document.querySelectorAll('[data-size]').forEach((b) => {
  b.onclick = () => { size = Number(b.dataset.size); store.set('puzzle.size', size); shuffle(); };
});
$('#shuffle').onclick = shuffle;
translatePage();
shuffle();
