#!/usr/bin/env node
/**
 * draw_quiz.js — 从题库抽题，并强制打乱选项顺序
 *
 * 为什么必须打乱：题库最容易犯的错是「答案位置偏移」——某个选项位堆满正确答案。
 * 实战中见过 131 题里 93 题答案都在 B 位（71%）的情况，直接刷等于练位置记忆，
 * 蒙一个字母就能拿七成分。所以本工具每次抽题都重排选项并重算答案字母。
 *
 * 用法：
 *   node draw_quiz.js --bank <bank.json> --course <课程代码> --n 10
 *   node draw_quiz.js --bank <bank.json> --course ALL --n 20 --key
 *   node draw_quiz.js --bank <bank.json> --course <课程代码> --n 10 --seed 7
 *   node draw_quiz.js --bank <bank.json> --check          # 只体检答案分布，不出题
 *
 * 题库格式（bank.json）：
 * {
 *   "questions": [
 *     { "id": 1, "course": "STAT101", "question": "...",
 *       "options": ["...","...","...","..."], "answerIndex": 1,
 *       "explanation": "..." }
 *   ]
 * }
 */

const fs = require('fs');

const LETTER = ['A', 'B', 'C', 'D', 'E', 'F'];

function mulberry32(a) {
  return function () {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function shuffle(arr, rnd) {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rnd() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function arg(name, fallback) {
  const i = process.argv.indexOf('--' + name);
  return i !== -1 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--')
    ? process.argv[i + 1]
    : fallback;
}

function fail(msg) {
  console.error('ERROR: ' + msg);
  process.exit(1);
}

function loadBank(p) {
  if (!p) fail('缺少 --bank <bank.json>');
  if (!fs.existsSync(p)) fail('找不到题库文件：' + p);
  let d;
  try { d = JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { fail('题库不是合法 JSON：' + e.message); }
  const qs = Array.isArray(d) ? d : d.questions;
  if (!Array.isArray(qs) || !qs.length) fail('题库里没有 questions 数组');
  return qs.map((q, i) => ({
    id: q.id != null ? q.id : i + 1,
    course: q.course || 'UNKNOWN',
    question: q.question || q.q || '',
    options: q.options || q.o || [],
    answerIndex: q.answerIndex != null ? q.answerIndex : q.a,
    explanation: q.explanation || q.ex || '',
  }));
}

function check(qs) {
  const dist = {};
  let bad = 0;
  for (const q of qs) {
    const c = q.course;
    dist[c] = dist[c] || { A: 0, B: 0, C: 0, D: 0, E: 0, F: 0 };
    const L = LETTER[q.answerIndex];
    if (L) dist[c][L]++; else bad++;
  }
  console.log('答案位置分布（理想是四等分）：\n');
  const codes = Object.keys(dist).sort();
  const head = ['course', 'n', 'A', 'B', 'C', 'D', 'E', 'F'].join('\t');
  console.log(head);
  let total = { A: 0, B: 0, C: 0, D: 0, E: 0, F: 0 }, n = 0;
  for (const c of codes) {
    const d = dist[c];
    const sum = Object.values(d).reduce((a, b) => a + b, 0);
    n += sum;
    for (const k of Object.keys(total)) total[k] += d[k];
    console.log([c, sum, d.A, d.B, d.C, d.D, d.E, d.F].join('\t'));
  }
  console.log(['TOTAL', n, total.A, total.B, total.C, total.D, total.E, total.F].join('\t'));
  console.log('\n占比：' + Object.entries(total)
    .filter(([, v]) => v)
    .map(([k, v]) => `${k} ${(v / n * 100).toFixed(0)}%`)
    .join('  '));
  const worst = Math.max(...Object.values(total));
  if (n && worst / n > 0.4) {
    console.log(`\n⚠️  最集中的答案位占了 ${(worst / n * 100).toFixed(0)}% —— 超过 40% 就该重排题库。`);
    console.log('   （出题时请人工分散答案位置；抽题时用 draw_quiz.js 即可自动打乱。）');
  }
  if (bad) console.log(`\n⚠️  有 ${bad} 题的 answerIndex 越界或缺失。`);
}

function isValidQ(q) {
  return Number.isInteger(q.answerIndex)
    && q.answerIndex >= 0
    && Array.isArray(q.options)
    && q.answerIndex < q.options.length;
}

function main() {
  const qs = loadBank(arg('bank', null));

  if (process.argv.includes('--check')) return check(qs);

  // 坏题（answerIndex 缺失/越界）必须剔除：留着会算出 LETTER[-1]，答案栏打出
  // "undefined" —— 比不出题更糟，因为看起来像出成功了。--check 会把这类题点出来。
  const valid = qs.filter(isValidQ);
  const badCount = qs.length - valid.length;
  if (badCount) {
    console.error(`WARN: ${badCount} 题的 answerIndex 缺失或越界，已剔除（跑 --check 可定位）`);
  }
  if (!valid.length) fail('题库里没有一道题的 answerIndex 是有效的 —— 先修题库（--check 可列出问题）');

  const course = (arg('course', 'ALL') || 'ALL').toUpperCase();
  const nRaw = arg('n', '10');
  const n = parseInt(nRaw, 10);
  if (!Number.isInteger(n) || n <= 0) fail(`--n 要是正整数（收到：${nRaw}）`);
  let seed = parseInt(arg('seed', '0'), 10);
  if (!seed) seed = Date.now() % 1000000;
  const showKey = process.argv.includes('--key');

  let pool = valid;
  if (course !== 'ALL') {
    pool = pool.filter(q => q.course.toUpperCase() === course);
    if (!pool.length) {
      const codes = [...new Set(qs.map(q => q.course))].join(', ');
      fail(`题库里没有 ${course} 的题。可选：ALL, ${codes}`);
    }
  }

  const rnd = mulberry32(seed);
  const picked = shuffle(pool, rnd).slice(0, Math.min(n, pool.length));

  const out = [];
  const key = [];
  out.push(`# 抽题 · ${course === 'ALL' ? '全部课程混合' : course} · ${picked.length} 题`, '');
  out.push(`> 选项已打乱（避免答案位置记忆）｜ seed=${seed}`, '');

  picked.forEach((q, i) => {
    const idx = shuffle(q.options.map((_, k) => k), rnd);
    const opts = idx.map(k => q.options[k]);
    const newAns = idx.indexOf(q.answerIndex);
    out.push(`**${i + 1}.**（${q.course}）${q.question}`, '');
    opts.forEach((o, k) => out.push(`- ${LETTER[k]}. ${o}`));
    out.push('');
    const line = `${i + 1}. **${LETTER[newAns]}** — ${String(q.explanation).replace(/\n/g, ' ')}`;
    key.push(line);
    if (showKey) { out.push('> 答案 ' + line.replace(/^\d+\. /, ''), ''); }
  });

  if (!showKey) {
    out.push('---', '', '## 答案与解析', '', ...key, '');
  }
  console.log(out.join('\n'));
}

main();
