'use strict';
/* global t, store, $, makeTimer, translatePage, showDialog */
// Sudoku: a random full grid, then cells removed one by one while the puzzle keeps exactly one solution.
// Progress (board, notes, time, mistakes) is saved so leaving the screen does not lose the game.

const HOLES = { easy: 38, medium: 48, hard: 56 };
const timer = makeTimer($('#time'));
let game = null; // { level, solution[81], given[81] bool, board[81], notes[81][], mistakes, seconds }
let selected = -1;
let noteMode = false;

const row = (i) => Math.floor(i / 9);
const col = (i) => i % 9;
const box = (i) => Math.floor(row(i) / 3) * 3 + Math.floor(col(i) / 3);
const peers = (a, b) => a !== b && (row(a) === row(b) || col(a) === col(b) || box(a) === box(b));

const PEERS = Array.from({ length: 81 }, (_, i) => [...Array(81).keys()].filter((j) => peers(i, j)));
const canPlace = (grid, i, v) => PEERS[i].every((j) => grid[j] !== v);
const options = (grid, i) => [1, 2, 3, 4, 5, 6, 7, 8, 9].filter((v) => canPlace(grid, i, v));

function shuffled(list) {
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

/** Counts solutions of [grid] by backtracking (grid is a scratch copy), stopping at [limit]. */
function solve(grid, limit) {
  // Branch on the empty cell with the fewest options: keeps uniqueness checks fast on hard boards.
  let best = -1; let bestOptions = null;
  for (let i = 0; i < 81; i++) {
    if (grid[i]) continue;
    const o = options(grid, i);
    if (!o.length) return 0;
    if (!bestOptions || o.length < bestOptions.length) { best = i; bestOptions = o; if (o.length === 1) break; }
  }
  if (best < 0) return 1;
  let count = 0;
  for (const v of bestOptions) {
    if (count >= limit) break;
    grid[best] = v;
    count += solve(grid, limit - count);
  }
  grid[best] = 0;
  return count;
}

function generate(level) {
  const solution = Array(81).fill(0);
  fillRandom(solution);
  const puzzle = [...solution];
  let removed = 0;
  for (const i of shuffled([...Array(81).keys()])) {
    if (removed >= HOLES[level]) break;
    const keep = puzzle[i];
    puzzle[i] = 0;
    if (solve([...puzzle], 2) === 1) removed++; else puzzle[i] = keep;
  }
  return {
    level, solution, given: puzzle.map((v) => v !== 0), board: puzzle,
    notes: Array.from({ length: 81 }, () => []), mistakes: 0, seconds: 0,
  };
}

function fillRandom(grid) {
  const i = grid.indexOf(0);
  if (i < 0) return true;
  for (const v of shuffled([1, 2, 3, 4, 5, 6, 7, 8, 9])) {
    if (!canPlace(grid, i, v)) continue;
    grid[i] = v;
    if (fillRandom(grid)) return true;
  }
  grid[i] = 0;
  return false;
}

function save() { game.seconds = timer.value(); store.set('sudoku.game', game); }

function newGame(level) {
  game = generate(level);
  store.set('sudoku.level', level);
  selected = -1;
  timer.start();
  save();
  render();
}

function enter(v) {
  if (selected < 0 || game.given[selected] || game.board[selected] === game.solution[selected]) return;
  if (noteMode) {
    const notes = game.notes[selected];
    game.notes[selected] = notes.includes(v) ? notes.filter((n) => n !== v) : [...notes, v].sort();
  } else {
    game.board[selected] = v;
    game.notes[selected] = [];
    if (v !== game.solution[selected]) game.mistakes++;
    else for (let j = 0; j < 81; j++) if (peers(selected, j)) game.notes[j] = game.notes[j].filter((n) => n !== v);
  }
  save();
  render();
  if (game.board.every((x, i) => x === game.solution[i])) {
    timer.stop();
    store.set('sudoku.game', null);
    showDialog(t('solved'), () => newGame(game.level));
  }
}

function erase() {
  if (selected < 0 || game.given[selected] || game.board[selected] === game.solution[selected]) return;
  game.board[selected] = 0; game.notes[selected] = [];
  save(); render();
}

function hint() {
  const empty = game.board.map((v, i) => (v === game.solution[i] ? -1 : i)).filter((i) => i >= 0);
  const target = empty.includes(selected) ? selected : empty[Math.floor(Math.random() * empty.length)];
  if (target === undefined) return;
  selected = target;
  const wasNotes = noteMode; noteMode = false;
  enter(game.solution[target]);
  noteMode = wasNotes;
}

function render() {
  const value = selected >= 0 ? game.board[selected] : 0;
  $('#grid').replaceChildren(...game.board.map((v, i) => {
    const b = document.createElement('button');
    b.type = 'button';
    const classes = ['cell', `c${col(i)}`, `r${row(i)}`];
    if (game.given[i]) classes.push('given');
    if (v && v !== game.solution[i]) classes.push('wrong');
    if (i === selected) classes.push('sel');
    else if (value && v === value) classes.push('same');
    else if (selected >= 0 && peers(i, selected)) classes.push('peer');
    b.className = classes.join(' ');
    if (v) b.textContent = v;
    else if (game.notes[i].length) {
      const notes = document.createElement('div');
      notes.className = 'notes';
      for (let n = 1; n <= 9; n++) { const s = document.createElement('span'); s.textContent = game.notes[i].includes(n) ? n : ''; notes.append(s); }
      b.append(notes);
    }
    b.setAttribute('aria-label', `${row(i) + 1}-${col(i) + 1}: ${v || ''}`);
    b.onclick = () => { selected = i; render(); };
    return b;
  }));
  const placed = (n) => game.board.filter((v, i) => v === n && v === game.solution[i]).length;
  $('#pad').replaceChildren(...[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => {
    const b = document.createElement('button');
    b.type = 'button'; b.textContent = n; b.disabled = placed(n) === 9;
    b.onclick = () => enter(n);
    return b;
  }));
  $('#mistakes').textContent = game.mistakes;
  $('#notes').setAttribute('aria-pressed', String(noteMode));
  document.querySelectorAll('[data-level]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.level === game.level)));
}

document.querySelectorAll('[data-level]').forEach((b) => { b.onclick = () => newGame(b.dataset.level); });
$('#new').onclick = () => newGame(game.level);
$('#notes').onclick = () => { noteMode = !noteMode; render(); };
$('#erase').onclick = erase;
$('#hint').onclick = hint;
document.addEventListener('keydown', (e) => {
  if (e.key >= '1' && e.key <= '9') enter(Number(e.key));
  if (e.key === 'Backspace' || e.key === 'Delete') erase();
});
document.addEventListener('visibilitychange', () => { if (game) save(); });
translatePage();

const saved = store.get('sudoku.game', null);
if (saved && Array.isArray(saved.board) && saved.board.length === 81 && HOLES[saved.level]) {
  game = saved; timer.start(saved.seconds || 0); render();
} else {
  newGame(store.get('sudoku.level', 'easy'));
}
