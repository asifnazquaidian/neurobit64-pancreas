// Long runs of the software model: what the chip reports in every condition.
// node summary.js   -> design/results/model_summary.txt and .json
'use strict';
const fs = require('fs'), path = require('path');
const C = require('./nb64_common.js'), M = require('./nb64_pancreas_model.js');
const rows = [], L = ['NeuroBit64-Pancreas, software model', '', 'A. Healthy islet at fixed glucose (8 s each; rates over the last 4 s)', '',
  'glucose in   beta Hz  alpha Hz  delta Hz  insulin %  glucose read  error'];
const resp = [];
for (const G of [40, 50, 60, 70, 80, 90, 100, 120, 140, 160, 180, 200, 240, 280]) {
  const c = new M.Chip({ cond: 0, keepFrames: false }); c.setGlucose(G); c.gin = G; c.run(4000); const a = c.tot.slice(); c.run(4000);
  const hz = (k, n) => +((c.tot[k] - a[k]) / n / 4).toFixed(1);
  const r = { glucose_in: G, beta_hz: hz(0, 594), alpha_hz: hz(1, 313), delta_hz: hz(2, 93), insulin_percent: Math.round((c.i2 >> 4) / 2.55), glucose_read: c.gest };
  resp.push(r); L.push(`${String(G).padStart(7)}     ${String(r.beta_hz).padStart(6)}  ${String(r.alpha_hz).padStart(8)}  ${String(r.delta_hz).padStart(8)}  ${String(r.insulin_percent).padStart(8)}  ${String(r.glucose_read).padStart(11)}  ${String(r.glucose_read - G).padStart(5)}`);
}
L.push('', 'B. All conditions, 32.8 s of model time (two glucose sweeps where the glucose is swept)', '',
  'cond  condition                                  brain chip  mean |read - in|  max   flags raised (% of reports)');
for (const link of [0, 1]) for (let cond = 0; cond < 8; cond++) {
  const nb = link ? new C.NeuroBit64S({ lif: 1, leak: 2, tsel: 4 }) : null;
  const c = new M.Chip({ cond, link, nb }); c.run(32768);
  const fr = c.frames.slice(64); let e = 0, mx = 0; for (const p of fr) { const d = Math.abs((p[10] | (p[11] << 8)) - (p[12] | (p[13] << 8))); e += d; mx = Math.max(mx, d); }
  const share = (bit) => Math.round(100 * fr.filter((p) => (p[2] >> bit) & 1).length / fr.length);
  const r = { condition: cond, name: c.K.name, brain_chip: link ? 'connected' : 'none', mean_abs_error_mg_dl: +(e / fr.length).toFixed(1), max_abs_error_mg_dl: mx,
    spikes_beta_alpha_delta: c.tot.slice(), flags_percent_of_reports: Object.fromEntries(M.FLAGS.map((n, i) => [n, n && i < 7 ? share(i) : 0]).filter(([, v]) => v > 0)), abnormal_percent: share(7) };
  rows.push(r);
  L.push(`${cond}     ${r.name.padEnd(41)}  ${r.brain_chip.padEnd(10)}  ${String(r.mean_abs_error_mg_dl).padStart(10)}      ${String(mx).padStart(4)}   ${Object.entries(r.flags_percent_of_reports).map(([k, v]) => `${k} ${v}`).join(', ') || 'none'}`);
}
const out = path.join(__dirname, '..', 'results');
fs.writeFileSync(path.join(out, 'model_summary.json'), JSON.stringify({ response: resp, conditions: rows }, null, 2));
fs.writeFileSync(path.join(out, 'model_summary.txt'), L.join('\n') + '\n'); console.log(L.join('\n'));
