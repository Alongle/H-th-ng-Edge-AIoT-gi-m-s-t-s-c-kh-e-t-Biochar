// Xuất dữ liệu huấn luyện ra ml/data/*.csv khi chưa có PostgreSQL thật.
// Dựng database trong bộ nhớ từ sql/ (PGlite, giống viewer) rồi chạy các file trong ml/queries/.
//   cd viewer && npm install        (một lần, để có PGlite)
//   node ml/export_data.mjs         (chạy từ thư mục edge_aiot_biochar_db, mất ~1 phút)
// Khi đã có PostgreSQL thật thì không cần file này: notebook đọc thẳng DB qua DATABASE_URL.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const require = createRequire(path.join(root, 'viewer', 'package.json'));
const { PGlite } = await import(pathToFileURL(require.resolve('@electric-sql/pglite')).href);

const sqlDir = path.join(root, 'sql');
const queryDir = path.join(here, 'queries');
const outDir = path.join(here, 'data');
fs.mkdirSync(outDir, { recursive: true });

const db = new PGlite();
const files = fs.readdirSync(sqlDir).filter(f => f.endsWith('.sql') && !f.startsWith('90_')).sort();
for (const f of files) {
  process.stdout.write(`Đang chạy ${f}...\n`);
  await db.exec(fs.readFileSync(path.join(sqlDir, f), 'utf8'));
}
await db.exec(`SET timezone = 'Asia/Ho_Chi_Minh'`);

const csvCell = v => {
  if (v === null || v === undefined) return '';
  const s = String(v);
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
};

for (const q of fs.readdirSync(queryDir).filter(f => f.endsWith('.sql'))) {
  const res = await db.query(fs.readFileSync(path.join(queryDir, q), 'utf8'));
  const cols = res.fields.map(f => f.name);
  const lines = [cols.join(','), ...res.rows.map(r => cols.map(c => csvCell(r[c])).join(','))];
  const out = path.join(outDir, q.replace(/\.sql$/, '.csv'));
  fs.writeFileSync(out, lines.join('\n') + '\n');
  console.log(`Đã ghi ${path.relative(root, out)} (${res.rows.length} dòng)`);
}
