// Trình xem database Edge-AIoT Biochar (chạy local, không cần cài PostgreSQL)
// Dùng PGlite = PostgreSQL chạy trong Node. Lần đầu khởi tạo ~1 phút, các lần sau dùng lại ./pgdata.
//   npm install
//   npm start        -> mở http://localhost:3000
//   npm run reset    -> xóa dữ liệu và khởi tạo lại
import { PGlite } from '@electric-sql/pglite';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sqlDir = path.join(here, '..', 'sql');
// Dữ liệu đặt ngoài OneDrive để tránh bị đồng bộ/khóa file trong lúc database chạy
const dataDir = process.env.PGDATA_DIR ||
  path.join(process.env.LOCALAPPDATA || os.homedir(), 'edge_aiot_biochar_pgdata');
const PORT = Number(process.env.PORT) || 3000;

if (process.argv.includes('--reset')) fs.rmSync(dataDir, { recursive: true, force: true });

const isNew = !fs.existsSync(path.join(dataDir, 'PG_VERSION'));
const db = new PGlite(dataDir);
let state = { ready: false, step: 'Đang khởi động...', error: null };

async function init() {
  await db.waitReady;
  if (isNew) {
    const files = fs.readdirSync(sqlDir).filter(f => f.endsWith('.sql') && !f.startsWith('90_')).sort();
    for (const f of files) {
      state.step = `Đang chạy ${f} (${files.indexOf(f) + 1}/${files.length})`;
      console.log(state.step);
      await db.exec(fs.readFileSync(path.join(sqlDir, f), 'utf8'));
    }
  }
  await db.exec(`SET timezone = 'Asia/Ho_Chi_Minh'`);
  state = { ready: true, step: 'Sẵn sàng', error: null };
  console.log(`Sẵn sàng: http://localhost:${PORT}`);
}

// Truy vấn cố định cho từng màn hình
const Q = {
  acceptance: `SELECT kpi_code, name_vi, unit, comparator, target_value, current_value, passed
               FROM reporting.v_acceptance_summary`,
  plots: `SELECT plot_code, soil_type, treatment_code, biochar_dose_kg_m2, node_code, node_status, gateway_code,
                 to_char(last_reading_at, 'DD/MM HH24:MI') last_reading, ph, ec, soil_moisture, n, p, k,
                 sqi_value, health_class, open_alerts, gateway_model_version
          FROM reporting.v_dashboard_plots ORDER BY plot_code`,
  counts: `SELECT (SELECT count(*) FROM iot.sensor_readings) readings,
                  (SELECT count(*) FROM iot.sensor_readings WHERE quality_status IN ('VALID','CORRECTED')) valid,
                  (SELECT count(*) FROM iot.sensor_nodes) nodes,
                  (SELECT count(*) FROM iot.gateways) gateways,
                  (SELECT count(*) FROM alert.alerts WHERE status <> 'RESOLVED') open_alerts,
                  (SELECT count(*) FROM laboratory.lab_results) lab_results`,
  monitoring: `SELECT p.plot_code, to_char(date_trunc('day', r.measured_at), 'YYYY-MM-DD') AS day,
                      round(avg(r.ph),2) ph, round(avg(r.ec),3) ec, round(avg(r.soil_moisture),2) moisture,
                      round(avg(r.soil_temperature),2) temp, round(avg(r.n),1) n, round(avg(r.p),1) p, round(avg(r.k),1) k
               FROM iot.sensor_readings r JOIN farm.plots p USING (plot_id)
               WHERE r.quality_status IN ('VALID','CORRECTED')
               GROUP BY 1, 2 ORDER BY 2, 1`,
  latestReadings: `SELECT p.plot_code, s.sensor_code, to_char(r.measured_at,'DD/MM HH24:MI') measured_at, r.ph, r.ec,
                          r.soil_moisture, r.soil_temperature, r.n, r.p, r.k, r.quality_status,
                          array_to_string(r.quality_flags, ', ') flags
                   FROM iot.sensor_readings r JOIN farm.plots p USING (plot_id) JOIN iot.sensors s USING (sensor_id)
                   ORDER BY r.measured_at DESC, p.plot_code LIMIT 60`,
  sqiDaily: `SELECT t.treatment_code, to_char(s.period_start,'YYYY-MM-DD') AS day, s.sqi_value, s.health_class
             FROM sqi.sqi_scores s JOIN experiment.treatments t USING (treatment_id) ORDER BY 2, 1`,
  sqiCompare: `SELECT treatment_code, treatment_name, biochar_dose_kg_m2, n_days, mean_sqi, sd_sqi, min_sqi, max_sqi, dominant_class
               FROM sqi.v_treatment_comparison ORDER BY treatment_code`,
  sqiIndicators: `SELECT t.treatment_code, i.parameter_code, round(avg(x.raw_value),3) raw_value,
                         round(avg(x.score),3) score, max(x.weight) weight
                  FROM sqi.sqi_indicator_scores x
                  JOIN sqi.sqi_scores s USING (sqi_score_id)
                  JOIN sqi.sqi_indicators i USING (indicator_id)
                  JOIN experiment.treatments t ON t.treatment_id = s.treatment_id
                  GROUP BY 1, 2 ORDER BY 2, 1`,
  experiment: `SELECT e.experiment_code, e.title, e.design_type, t.treatment_code, t.name, t.biochar_dose_kg_m2,
                      t.control_flag, b.batch_code biochar_batch, en.batch_code enrichment_batch, p.plot_code,
                      to_char(ta.effective_from,'DD/MM/YYYY') from_date
               FROM experiment.treatments t
               JOIN experiment.experiments e USING (experiment_id)
               LEFT JOIN biochar.biochar_batches b ON b.biochar_batch_id = t.biochar_batch_id
               LEFT JOIN biochar.enrichment_batches en ON en.enrichment_batch_id = t.enrichment_batch_id
               LEFT JOIN experiment.treatment_applications ta ON ta.treatment_id = t.treatment_id
               LEFT JOIN farm.plots p ON p.plot_id = ta.plot_id ORDER BY t.treatment_code`,
  biochar: `SELECT b.batch_code, f.batch_code feedstock, f.feedstock_type, b.pyrolysis_temp_c, b.residence_time_min,
                   b.input_mass_kg, b.output_mass_kg, b.yield_pct, b.ph, b.carbon_pct, b.surface_area_m2_g,
                   b.heavy_metals_mg_kg::text heavy_metals, b.safety_status
            FROM biochar.biochar_batches b JOIN biochar.feedstock_batches f USING (feedstock_batch_id)`,
  calibration: `SELECT s.sensor_code, r.parameter_code, round(r.slope,4) slope, round(r.intercept,4) intercept,
                       r.r2, round(r.rmse,4) rmse, round(r.repeatability_cv_pct,3) cv_pct, r.passed
                FROM calibration.calibration_results r JOIN iot.sensors s USING (sensor_id) ORDER BY 1, 2`,
  sensorVsLab: `SELECT sample_code, parameter_code, round(lab_value,2) lab_value, round(sensor_value,2) sensor_value,
                       diff_pct, n_readings
                FROM laboratory.v_sensor_vs_lab ORDER BY sample_code, parameter_code`,
  dqDaily: `SELECT to_char(day,'YYYY-MM-DD') AS day, sum(expected) expected, sum(received) received, sum(valid) valid,
                   sum(invalid) invalid, sum(duplicates) duplicates
            FROM reporting.v_data_collection_daily GROUP BY day ORDER BY day`,
  dqIssues: `SELECT issue_type, severity, count(*) n FROM data_quality.data_issues GROUP BY 1, 2 ORDER BY 3 DESC`,
  dqRules: `SELECT rule_code, name, rule_type, parameter_code, min_value, max_value, max_delta, severity
            FROM data_quality.quality_rules ORDER BY rule_code`,
  dataset: `SELECT dataset_code, version_no, status, split_strategy, records, valid_records, labeled_records,
                   train, val, test, meets_min_observations, leaking_groups
            FROM dataset.v_version_readiness`,
  labels: `SELECT l.label_code, l.name_vi, r.split, count(*) n
           FROM dataset.dataset_records r JOIN dataset.labels l USING (label_id)
           GROUP BY 1, 2, 3, l.class_order ORDER BY l.class_order, 3`,
  ml: `SELECT model_code, task_type, version, status, accuracy, precision, recall, f1, n_inferences,
              latency_ms_avg, latency_ms_p95, passed
       FROM ml.v_model_acceptance ORDER BY model_code, version`,
  inference: `SELECT mo.model_code, p.plot_code, to_char(i.inferred_at,'DD/MM HH24:MI') inferred_at, i.predicted_label,
                     i.confidence, round(i.anomaly_score, 3) anomaly_score, i.is_anomaly, i.latency_ms
              FROM ml.inference_results i JOIN ml.model_versions mv USING (model_version_id)
              JOIN ml.models mo USING (model_id) LEFT JOIN farm.plots p ON p.plot_id = i.plot_id
              ORDER BY i.inferred_at DESC LIMIT 40`,
  ota: `SELECT package_type, finished, succeeded, success_rate_pct, avg_duration_min, max_duration_min, over_10_min
        FROM ota.v_ota_kpi`,
  otaDeploy: `SELECT p.package_code, p.package_type, g.gateway_code, n.node_code, d.status, d.progress_pct,
                     d.integrity_ok, to_char(d.started_at,'DD/MM HH24:MI') started, round(d.duration_s/60, 2) minutes
              FROM ota.ota_deployments d JOIN ota.ota_packages p USING (package_id)
              JOIN iot.gateways g USING (gateway_id) LEFT JOIN iot.sensor_nodes n ON n.node_id = d.node_id
              ORDER BY d.created_at`,
  alerts: `SELECT to_char(a.created_at,'DD/MM/YYYY HH24:MI') created_at, a.severity, a.source, a.message, a.status,
                  rc.category, rc.action_text recommendation
           FROM alert.alerts a LEFT JOIN alert.recommendations rc ON rc.alert_id = a.alert_id
           ORDER BY a.created_at DESC`,
  alertRules: `SELECT rule_code, name, source, parameter_code, condition, threshold_low, threshold_high, severity
               FROM alert.alert_rules ORDER BY rule_code`,
  economic: `SELECT t.treatment_code, t.name, e.yield_t_ha, e.revenue_vnd_ha, e.total_cost_vnd_ha, e.profit_vnd_ha,
                    e.bcr, e.carbon_sequestered_kg_ha
             FROM reporting.economic_results e JOIN experiment.treatments t USING (treatment_id) ORDER BY 1`,
  tables: `SELECT n.nspname AS schema, c.relname AS table, c.reltuples::bigint AS approx_rows,
                  CASE c.relkind WHEN 'p' THEN 'partitioned' WHEN 'v' THEN 'view' ELSE 'table' END kind
           FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname IN ('ref','iam','farm','experiment','biochar','iot','calibration','laboratory',
                               'data_quality','dataset','sqi','ml','ota','alert','reporting','audit')
             AND c.relkind IN ('r','p','v') AND NOT c.relispartition
           ORDER BY 1, 2`,
};

const send = (res, code, body, type = 'application/json; charset=utf-8') => {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store' });
  res.end(typeof body === 'string' ? body : JSON.stringify(body));
};

const result = r => ({ fields: r.fields.map(f => f.name), rows: r.rows });

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname === '/') return send(res, 200, fs.readFileSync(path.join(here, 'index.html'), 'utf8'), 'text/html; charset=utf-8');
    if (url.pathname === '/api/status') return send(res, 200, state);
    if (!state.ready) return send(res, 503, { error: state.step });

    if (url.pathname === '/api/q') {
      const sql = Q[url.searchParams.get('name')];
      if (!sql) return send(res, 404, { error: 'Không có truy vấn này' });
      return send(res, 200, result(await db.query(sql)));
    }
    if (url.pathname === '/api/table') {
      const schema = url.searchParams.get('schema'), table = url.searchParams.get('table');
      const ok = await db.query(`SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                                 WHERE n.nspname = $1 AND c.relname = $2`, [schema, table]);
      if (!ok.rows.length) return send(res, 404, { error: 'Không có bảng này' });
      const qi = s => '"' + s.replace(/"/g, '""') + '"';
      return send(res, 200, result(await db.query(`SELECT * FROM ${qi(schema)}.${qi(table)} LIMIT 200`)));
    }
    if (url.pathname === '/api/sql' && req.method === 'POST') {
      let body = '';
      for await (const chunk of req) body += chunk;
      // Chạy trong transaction rồi ROLLBACK để không làm hỏng dữ liệu demo
      await db.exec('BEGIN');
      try {
        return send(res, 200, result(await db.query(body)));
      } finally {
        await db.exec('ROLLBACK');
      }
    }
    send(res, 404, { error: 'Not found' });
  } catch (e) {
    send(res, 400, { error: e.message });
  }
}).listen(PORT, () => console.log(`Trình xem đang chạy: http://localhost:${PORT}`));

init().catch(e => { state = { ready: false, step: 'Lỗi khởi tạo', error: e.message }; console.error(e); });
