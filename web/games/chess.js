'use strict';
/* global t, store, $, translatePage, showDialog */
// Chess with full legal moves (castling, en passant, promotion, check, mate, stalemate) and an
// alpha-beta computer. Board: 64 cells, index 0 = a8; pieces 'PNBRQK' white, 'pnbrqk' black, '' empty.
// shortcut: promotion always makes a queen and draws cover stalemate + bare kings/minor piece only
// (no threefold repetition or 50-move rule); add a promotion picker and those rules if players ask.

const GLYPH = { k: '♚', q: '♛', r: '♜', b: '♝', n: '♞', p: '♟' };
const VALUE = { p: 100, n: 320, b: 330, r: 500, q: 900, k: 0 };
const KNIGHT = [[-2, -1], [-2, 1], [-1, -2], [-1, 2], [1, -2], [1, 2], [2, -1], [2, 1]];
const KING = [[-1, -1], [-1, 0], [-1, 1], [0, -1], [0, 1], [1, -1], [1, 0], [1, 1]];
const ROOK = [[-1, 0], [1, 0], [0, -1], [0, 1]];
const BISHOP = [[-1, -1], [-1, 1], [1, -1], [1, 1]];
const inside = (r, c) => r >= 0 && r < 8 && c >= 0 && c < 8;
const colour = (p) => (p ? (p === p.toUpperCase() ? 'w' : 'b') : '');
const kind = (p) => p.toLowerCase();

function startPosition() {
  const back = 'rnbqkbnr';
  const board = Array(64).fill('');
  for (let c = 0; c < 8; c++) {
    board[c] = back[c]; board[8 + c] = 'p';
    board[48 + c] = 'P'; board[56 + c] = back[c].toUpperCase();
  }
  return { board, turn: 'w', castle: 'KQkq', ep: -1 };
}

/** True when [side]'s pieces attack square [sq]. */
function attacked(board, sq, side) {
  const r0 = Math.floor(sq / 8); const c0 = sq % 8;
  const is = (r, c, kinds) => inside(r, c) && colour(board[r * 8 + c]) === side && kinds.includes(kind(board[r * 8 + c]));
  const pawnRow = side === 'w' ? r0 + 1 : r0 - 1;
  if (is(pawnRow, c0 - 1, 'p') || is(pawnRow, c0 + 1, 'p')) return true;
  if (KNIGHT.some(([dr, dc]) => is(r0 + dr, c0 + dc, 'n'))) return true;
  if (KING.some(([dr, dc]) => is(r0 + dr, c0 + dc, 'k'))) return true;
  const ray = (dirs, kinds) => dirs.some(([dr, dc]) => {
    for (let r = r0 + dr, c = c0 + dc; inside(r, c); r += dr, c += dc) {
      if (board[r * 8 + c]) return is(r, c, kinds);
    }
    return false;
  });
  return ray(ROOK, 'rq') || ray(BISHOP, 'bq');
}

const kingSquare = (board, side) => board.indexOf(side === 'w' ? 'K' : 'k');
const inCheck = (pos, side) => attacked(pos.board, kingSquare(pos.board, side), side === 'w' ? 'b' : 'w');

function pseudoMoves(pos) {
  const { board, turn, castle, ep } = pos;
  const enemy = turn === 'w' ? 'b' : 'w';
  const moves = [];
  const add = (from, to, extra = {}) => moves.push({ from, to, captured: board[to], ...extra });
  for (let from = 0; from < 64; from++) {
    const p = board[from];
    if (colour(p) !== turn) continue;
    const r0 = Math.floor(from / 8); const c0 = from % 8;
    const k = kind(p);
    if (k === 'p') {
      const dir = turn === 'w' ? -1 : 1;
      const lastRow = turn === 'w' ? 0 : 7;
      const step = (from + dir * 8);
      if (inside(r0 + dir, c0) && !board[step]) {
        add(from, step, { promo: r0 + dir === lastRow });
        const startRow = turn === 'w' ? 6 : 1;
        if (r0 === startRow && !board[step + dir * 8]) add(from, step + dir * 8, { double: true });
      }
      for (const dc of [-1, 1]) {
        if (!inside(r0 + dir, c0 + dc)) continue;
        const to = (r0 + dir) * 8 + c0 + dc;
        if (colour(board[to]) === enemy) add(from, to, { promo: r0 + dir === lastRow });
        else if (to === ep) moves.push({ from, to, captured: turn === 'w' ? 'p' : 'P', enPassant: true });
      }
      continue;
    }
    if (k === 'n' || k === 'k') {
      for (const [dr, dc] of k === 'n' ? KNIGHT : KING) {
        const r = r0 + dr; const c = c0 + dc;
        if (inside(r, c) && colour(board[r * 8 + c]) !== turn) add(from, r * 8 + c);
      }
    } else {
      const dirs = k === 'r' ? ROOK : k === 'b' ? BISHOP : [...ROOK, ...BISHOP];
      for (const [dr, dc] of dirs) {
        for (let r = r0 + dr, c = c0 + dc; inside(r, c); r += dr, c += dc) {
          const target = board[r * 8 + c];
          if (colour(target) === turn) break;
          add(from, r * 8 + c);
          if (target) break;
        }
      }
    }
    if (k === 'k') {
      const home = turn === 'w' ? 60 : 4;
      const [kingSide, queenSide] = turn === 'w' ? ['K', 'Q'] : ['k', 'q'];
      if (from === home && !attacked(board, home, enemy)) {
        if (castle.includes(kingSide) && !board[home + 1] && !board[home + 2]
          && !attacked(board, home + 1, enemy)) add(from, home + 2, { castle: true });
        if (castle.includes(queenSide) && !board[home - 1] && !board[home - 2] && !board[home - 3]
          && !attacked(board, home - 1, enemy)) add(from, home - 2, { castle: true });
      }
    }
  }
  return moves;
}

function makeMove(pos, m) {
  const board = [...pos.board];
  const piece = board[m.from];
  board[m.to] = m.promo ? (pos.turn === 'w' ? 'Q' : 'q') : piece;
  board[m.from] = '';
  if (m.enPassant) board[m.to + (pos.turn === 'w' ? 8 : -8)] = '';
  if (m.castle) {
    const rookFrom = m.to > m.from ? m.from + 3 : m.from - 4;
    const rookTo = m.to > m.from ? m.from + 1 : m.from - 1;
    board[rookTo] = board[rookFrom]; board[rookFrom] = '';
  }
  // Moving a king or a rook, or capturing a rook at home, loses those castling rights.
  const lost = { 60: 'KQ', 4: 'kq', 63: 'K', 56: 'Q', 7: 'k', 0: 'q' };
  const castle = [...pos.castle].filter((r) => !(lost[m.from] || '').includes(r) && !(lost[m.to] || '').includes(r)).join('');
  return { board, turn: pos.turn === 'w' ? 'b' : 'w', castle, ep: m.double ? (m.from + m.to) / 2 : -1 };
}

function legalMoves(pos) {
  return pseudoMoves(pos).filter((m) => !inCheck(makeMove(pos, m), pos.turn));
}

function insufficient(board) {
  const rest = board.filter((p) => p && kind(p) !== 'k');
  return rest.length === 0 || (rest.length === 1 && 'nb'.includes(kind(rest[0])));
}

// Centre bonus for knights/bishops/pawns, pawn advance bonus; enough for a casual opponent.
function evaluate(pos) {
  let score = 0;
  pos.board.forEach((p, i) => {
    if (!p) return;
    const r = Math.floor(i / 8); const c = i % 8;
    const k = kind(p);
    const centre = 3.5 - Math.max(Math.abs(r - 3.5), Math.abs(c - 3.5));
    let v = VALUE[k];
    if ('nbq'.includes(k)) v += centre * 8;
    if (k === 'p') v += (colour(p) === 'w' ? 6 - r : r - 1) * 8 + (centre > 1.5 ? 10 : 0);
    score += colour(p) === 'w' ? v : -v;
  });
  return pos.turn === 'w' ? score : -score;
}

const ordered = (moves) => moves.sort((a, b) => (b.captured ? VALUE[kind(b.captured)] : 0) - (a.captured ? VALUE[kind(a.captured)] : 0));

function search(pos, depth, alpha, beta) {
  const moves = legalMoves(pos);
  if (!moves.length) return inCheck(pos, pos.turn) ? -100000 - depth : 0;
  if (depth === 0) return quiesce(pos, alpha, beta, 4);
  for (const m of ordered(moves)) {
    const score = -search(makeMove(pos, m), depth - 1, -beta, -alpha);
    if (score >= beta) return score;
    if (score > alpha) alpha = score;
  }
  return alpha;
}

/** Follows captures past the horizon so the computer does not hang pieces. */
function quiesce(pos, alpha, beta, left) {
  const stand = evaluate(pos);
  if (stand >= beta || left === 0) return stand;
  if (stand > alpha) alpha = stand;
  for (const m of ordered(pseudoMoves(pos).filter((x) => x.captured))) {
    const next = makeMove(pos, m);
    if (inCheck(next, pos.turn)) continue;
    const score = -quiesce(next, -beta, -alpha, left - 1);
    if (score >= beta) return score;
    if (score > alpha) alpha = score;
  }
  return alpha;
}

function bestMove(pos, depth) {
  const moves = ordered(legalMoves(pos).sort(() => Math.random() - 0.5));
  let best = moves[0]; let alpha = -Infinity;
  for (const m of moves) {
    const score = -search(makeMove(pos, m), depth - 1, -Infinity, -alpha);
    if (score > alpha) { alpha = score; best = m; }
  }
  return best;
}

// ---- UI ----
let mode = store.get('chess.mode', 'ai');
let depth = store.get('chess.depth', 2);
let pos; let history; let selected; let last; let over; let thinking;

function newGame() {
  pos = startPosition(); history = []; selected = -1; last = null; over = false; thinking = false;
  render();
}

function outcome() {
  if (legalMoves(pos).length) return insufficient(pos.board) ? t('draw') : '';
  if (!inCheck(pos, pos.turn)) return t('draw');
  const winner = pos.turn === 'w' ? 'b' : 'w';
  if (mode === 'ai') return winner === 'w' ? t('you_won') : t('you_lost');
  return winner === 'w' ? t('white_won') : t('black_won');
}

function commit(m) {
  history.push({ pos, last });
  pos = makeMove(pos, m); last = m; selected = -1;
  const result = outcome();
  if (result) {
    over = true; render(result);
    setTimeout(() => showDialog(result, newGame), 400);
    return;
  }
  render();
  if (mode === 'ai' && pos.turn === 'b') {
    thinking = true; render();
    setTimeout(() => { thinking = false; commit(bestMove(pos, depth)); }, 200);
  }
}

function tap(i) {
  if (over || thinking || (mode === 'ai' && pos.turn === 'b')) return;
  const choice = legalMoves(pos).find((m) => m.from === selected && m.to === i);
  if (choice) { commit(choice); return; }
  selected = colour(pos.board[i]) === pos.turn ? i : -1;
  render();
}

function undo() {
  if (thinking || !history.length) return;
  let steps = mode === 'ai' ? (pos.turn === 'w' ? 2 : 1) : 1;
  while (steps-- > 0 && history.length) ({ pos, last } = history.pop());
  over = false; selected = -1;
  render();
}

function capturedBy(side) {
  const start = 'pppppppp' + 'rnbqkbnr';
  const want = side === 'w' ? start : start.toUpperCase();
  const left = [...pos.board];
  const out = [];
  for (const p of want) {
    const at = left.indexOf(p);
    if (at >= 0) left[at] = ''; else out.push(GLYPH[kind(p)]);
  }
  return out.join('︎');
}

function render(message) {
  const targets = new Set(selected >= 0 ? legalMoves(pos).filter((m) => m.from === selected).map((m) => m.to) : []);
  const checked = inCheck(pos, pos.turn) ? kingSquare(pos.board, pos.turn) : -1;
  $('#board').replaceChildren(...pos.board.map((p, i) => {
    const sq = document.createElement('button');
    sq.type = 'button';
    const dark = (Math.floor(i / 8) + (i % 8)) % 2 === 1;
    const isLast = last && (last.from === i || last.to === i);
    sq.className = `sq ${dark ? 'd' : 'l'}${i === selected ? ' sel' : ''}${targets.has(i) ? ' target' : ''}${isLast && i !== selected ? ' last' : ''}${i === checked ? ' check' : ''}`;
    if (p) {
      const glyph = document.createElement('span');
      glyph.className = colour(p);
      glyph.textContent = `${GLYPH[kind(p)]}︎`; // text presentation, not the emoji pawn
      sq.append(glyph);
    }
    sq.onclick = () => tap(i);
    return sq;
  }));
  $('#taken-w').textContent = capturedBy('w');
  $('#taken-b').textContent = capturedBy('b');
  const status = $('#status');
  status.className = `status${message ? ' win' : checked >= 0 ? ' bad' : ''}`;
  const turnText = mode === 'ai' ? t('your_turn') : t(pos.turn === 'w' ? 'white_turn' : 'black_turn');
  status.textContent = message || (thinking ? t('thinking') : `${turnText}${checked >= 0 ? ` · ${t('check')}` : ''}`);
  $('#undo').disabled = !history.length || thinking;
  $('#levels').hidden = mode !== 'ai';
  document.querySelectorAll('[data-mode]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === mode)));
  document.querySelectorAll('[data-level]').forEach((b) => b.setAttribute('aria-pressed', String(Number(b.dataset.level) === depth)));
}

document.querySelectorAll('[data-mode]').forEach((b) => { b.onclick = () => { mode = b.dataset.mode; store.set('chess.mode', mode); newGame(); }; });
document.querySelectorAll('[data-level]').forEach((b) => { b.onclick = () => { depth = Number(b.dataset.level); store.set('chess.depth', depth); render(); }; });
$('#new').onclick = newGame;
$('#undo').onclick = undo;
translatePage();
newGame();
