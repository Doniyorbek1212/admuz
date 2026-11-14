'use strict';
/* global t, store, $, translatePage, showDialog */
// Russian draughts. Board: 64 cells, 1 white man, 2 white king, -1 black man, -2 black king, 0 empty.
// White sits at the bottom and moves first. Capturing is mandatory; men capture backwards too;
// kings fly; a jump sequence continues while possible; jumped pieces leave the board only after the
// sequence ends (they block meanwhile, and none can be jumped twice); a man that reaches the last row
// mid-sequence carries on as a king.

const DIRS = [[-1, -1], [-1, 1], [1, -1], [1, 1]];
const inside = (r, c) => r >= 0 && r < 8 && c >= 0 && c < 8;
const side = (p) => Math.sign(p);

function startBoard() {
  const b = Array(64).fill(0);
  for (let i = 0; i < 64; i++) {
    const r = Math.floor(i / 8); const c = i % 8;
    if ((r + c) % 2 === 1) b[i] = r < 3 ? -1 : r > 4 ? 1 : 0;
  }
  return b;
}

function jumps(board, path, captured, piece, out) {
  const from = path[path.length - 1];
  const r0 = Math.floor(from / 8); const c0 = from % 8;
  const empty = (i) => board[i] === 0 || i === path[0];
  let extended = false;
  for (const [dr, dc] of DIRS) {
    let r = r0 + dr; let c = c0 + dc;
    if (Math.abs(piece) === 2) while (inside(r, c) && empty(r * 8 + c)) { r += dr; c += dc; }
    if (!inside(r, c)) continue;
    const over = r * 8 + c;
    if (side(board[over]) !== -side(piece) || captured.includes(over) || over === path[0]) continue;
    for (let lr = r + dr, lc = c + dc; inside(lr, lc) && empty(lr * 8 + lc); lr += dr, lc += dc) {
      const land = lr * 8 + lc;
      const crowned = Math.abs(piece) === 1 && lr === (piece > 0 ? 0 : 7) ? piece * 2 : piece;
      extended = true;
      jumps(board, [...path, land], [...captured, over], crowned, out);
      if (Math.abs(piece) === 1) break; // a man lands right behind the piece it jumps
    }
  }
  if (!extended && captured.length) out.push({ path, captured, piece });
}

/** Every legal move for [turn] (1 white, -1 black): captures if any exist, otherwise quiet moves. */
function legalMoves(board, turn) {
  const caps = [];
  for (let i = 0; i < 64; i++) if (side(board[i]) === turn) jumps(board, [i], [], board[i], caps);
  if (caps.length) return caps;
  const quiet = [];
  for (let i = 0; i < 64; i++) {
    const p = board[i];
    if (side(p) !== turn) continue;
    const r0 = Math.floor(i / 8); const c0 = i % 8;
    for (const [dr, dc] of DIRS) {
      if (Math.abs(p) === 1 && dr !== -turn) continue; // men step forward only
      for (let r = r0 + dr, c = c0 + dc; inside(r, c) && board[r * 8 + c] === 0; r += dr, c += dc) {
        const promote = Math.abs(p) === 1 && r === (turn > 0 ? 0 : 7);
        quiet.push({ path: [i, r * 8 + c], captured: [], piece: promote ? p * 2 : p });
        if (Math.abs(p) === 1) break;
      }
    }
  }
  return quiet;
}

function play(board, move) {
  const next = [...board];
  next[move.path[0]] = 0;
  for (const i of move.captured) next[i] = 0;
  next[move.path[move.path.length - 1]] = move.piece;
  return next;
}

function evaluate(board) {
  let score = 0;
  for (let i = 0; i < 64; i++) {
    const p = board[i];
    if (!p) continue;
    const r = Math.floor(i / 8);
    const advance = p === 1 ? 7 - r : p === -1 ? r : 0;
    score += side(p) * ((Math.abs(p) === 2 ? 320 : 100) + advance * 4);
  }
  return score; // positive favours white
}

function search(board, turn, depth, alpha, beta) {
  const moves = legalMoves(board, turn);
  if (!moves.length) return -100000 - depth; // side to move has lost; sooner is worse
  if (depth === 0) return turn * evaluate(board);
  let best = -Infinity;
  for (const m of moves) {
    const score = -search(play(board, m), -turn, depth - 1, -beta, -alpha);
    if (score > best) best = score;
    if (best > alpha) alpha = best;
    if (alpha >= beta) break;
  }
  return best;
}

function bestMove(board, turn, depth) {
  const moves = legalMoves(board, turn).sort(() => Math.random() - 0.5);
  let best = moves[0]; let bestScore = -Infinity;
  for (const m of moves) {
    const score = -search(play(board, m), -turn, depth - 1, -Infinity, -bestScore);
    if (score > bestScore) { bestScore = score; best = m; }
  }
  return best;
}

// ---- UI ----
let mode = store.get('checkers.mode', 'ai');
let depth = store.get('checkers.depth', 5);
let board; let turn; let history; let selected; let last; let over; let thinking;

function newGame() {
  board = startBoard(); turn = 1; history = []; selected = -1; last = null; over = false; thinking = false;
  render();
}

function commit(move) {
  history.push({ board, turn, last });
  board = play(board, move); turn = -turn; last = move; selected = -1;
  render();
  const replies = legalMoves(board, turn);
  if (!replies.length) {
    over = true;
    const winner = -turn;
    const text = mode === 'ai' ? (winner === 1 ? t('you_won') : t('you_lost')) : (winner === 1 ? t('white_won') : t('black_won'));
    render(text);
    setTimeout(() => showDialog(text, newGame), 400);
    return;
  }
  if (mode === 'ai' && turn === -1) {
    thinking = true; render();
    setTimeout(() => { thinking = false; commit(bestMove(board, -1, depth)); }, 250);
  }
}

function tap(i) {
  if (over || thinking || (mode === 'ai' && turn === -1)) return;
  const moves = legalMoves(board, turn);
  const choice = moves.filter((m) => m.path[0] === selected && m.path[m.path.length - 1] === i)
    .sort((a, b) => b.captured.length - a.captured.length)[0];
  if (choice) { commit(choice); return; }
  selected = moves.some((m) => m.path[0] === i) ? i : -1;
  render();
}

function undo() {
  if (thinking || !history.length) return;
  let steps = mode === 'ai' ? (turn === 1 ? 2 : 1) : 1;
  while (steps-- > 0 && history.length) ({ board, turn, last } = history.pop());
  over = false; selected = -1;
  render();
}

function render(message) {
  const moves = over ? [] : legalMoves(board, turn);
  const humanTurn = !(mode === 'ai' && turn === -1);
  const movable = new Set(humanTurn ? moves.map((m) => m.path[0]) : []);
  const targets = new Set(moves.filter((m) => m.path[0] === selected).map((m) => m.path[m.path.length - 1]));
  const lastSquares = new Set(last ? [...last.path] : []);
  $('#board').replaceChildren(...board.map((p, i) => {
    const sq = document.createElement('button');
    sq.type = 'button';
    const dark = (Math.floor(i / 8) + (i % 8)) % 2 === 1;
    sq.className = `sq ${dark ? 'd' : 'l'}${i === selected ? ' sel' : ''}${targets.has(i) ? ' target' : ''}${lastSquares.has(i) && i !== selected ? ' last' : ''}${movable.has(i) && selected < 0 ? ' movable' : ''}`;
    if (p) {
      const piece = document.createElement('span');
      piece.className = `piece ${p > 0 ? 'w' : 'b'}${Math.abs(p) === 2 ? ' k' : ''}`;
      sq.append(piece);
    }
    if (!dark) sq.tabIndex = -1;
    sq.onclick = () => tap(i);
    return sq;
  }));
  const status = $('#status');
  const capture = moves.length && moves[0].captured.length && humanTurn;
  status.className = `status${message ? ' win' : ''}`;
  status.textContent = message || (thinking ? t('thinking')
    : `${mode === 'ai' ? t('your_turn') : t(turn === 1 ? 'white_turn' : 'black_turn')}${capture ? ` · ${t('must_capture')}` : ''}`);
  $('#undo').disabled = !history.length || thinking;
  $('#levels').hidden = mode !== 'ai';
  document.querySelectorAll('[data-mode]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === mode)));
  document.querySelectorAll('[data-level]').forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.level) === depth)));
}

document.querySelectorAll('[data-mode]').forEach((b) => { b.onclick = () => { mode = b.dataset.mode; store.set('checkers.mode', mode); newGame(); }; });
document.querySelectorAll('[data-level]').forEach((b) => { b.onclick = () => { depth = Number(b.dataset.level); store.set('checkers.depth', depth); render(); }; });
$('#new').onclick = newGame;
$('#undo').onclick = undo;
translatePage();
newGame();
