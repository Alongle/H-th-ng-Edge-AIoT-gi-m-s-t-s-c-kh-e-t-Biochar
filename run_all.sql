-- Chạy toàn bộ bằng psql từ thư mục edge_aiot_biochar_db:
--   createdb edge_aiot_biochar
--   psql -d edge_aiot_biochar -v ON_ERROR_STOP=1 -f run_all.sql
\set ON_ERROR_STOP on
\i sql/00_init.sql
\i sql/01_iam.sql
\i sql/02_farm.sql
\i sql/03_biochar.sql
\i sql/04_experiment.sql
\i sql/05_iot.sql
\i sql/06_calibration.sql
\i sql/07_laboratory.sql
\i sql/08_data_quality.sql
\i sql/09_dataset.sql
\i sql/10_sqi.sql
\i sql/11_ml.sql
\i sql/12_ota.sql
\i sql/13_alert.sql
\i sql/14_reporting.sql
\i sql/15_audit.sql
\i sql/16_reference_data.sql
\i sql/17_db_roles.sql
-- Dữ liệu demo (bỏ dòng này trên production):
\i sql/99_demo_seed.sql
