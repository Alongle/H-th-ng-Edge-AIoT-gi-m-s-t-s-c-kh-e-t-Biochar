-- >>>>> 00_init.sql
-- =====================================================================
-- Edge-AIoT giám sát sức khỏe đất – Biochar
-- 00_init.sql : schema, kiểu dùng chung, hàm tiện ích
-- Yêu cầu: PostgreSQL >= 14 (gen_random_uuid() có sẵn trong core)
-- =====================================================================

-- Múi giờ Việt Nam cho date_trunc theo ngày (KPI, SQI ngày). Áp dụng cho session mới.
DO $$ BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone = %L', current_database(), 'Asia/Ho_Chi_Minh');
END $$;
SET timezone = 'Asia/Ho_Chi_Minh';

CREATE SCHEMA IF NOT EXISTS ref;           -- danh mục dùng chung (chỉ tiêu, đơn vị)
CREATE SCHEMA IF NOT EXISTS iam;
CREATE SCHEMA IF NOT EXISTS farm;
CREATE SCHEMA IF NOT EXISTS experiment;
CREATE SCHEMA IF NOT EXISTS biochar;
CREATE SCHEMA IF NOT EXISTS iot;
CREATE SCHEMA IF NOT EXISTS calibration;
CREATE SCHEMA IF NOT EXISTS laboratory;
CREATE SCHEMA IF NOT EXISTS data_quality;
CREATE SCHEMA IF NOT EXISTS dataset;
CREATE SCHEMA IF NOT EXISTS sqi;
CREATE SCHEMA IF NOT EXISTS ml;
CREATE SCHEMA IF NOT EXISTS ota;
CREATE SCHEMA IF NOT EXISTS alert;
CREATE SCHEMA IF NOT EXISTS reporting;
CREATE SCHEMA IF NOT EXISTS audit;

-- ---------------------------------------------------------------------
-- Hàm tự cập nhật updated_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ref.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- Danh mục chỉ tiêu đo (dùng chung cho sensor, lab, SQI, QC, alert)
-- ---------------------------------------------------------------------
CREATE TABLE ref.parameters (
    parameter_code  VARCHAR(32)  PRIMARY KEY,           -- PH, EC, MOISTURE, N, P, K, ...
    name_vi         VARCHAR(128) NOT NULL,
    unit            VARCHAR(32)  NOT NULL,
    category        VARCHAR(32)  NOT NULL
                    CHECK (category IN ('SOIL_CHEM','SOIL_PHYS','SOIL_BIO','BIOCHAR','PLANT','ENV')),
    physical_min    NUMERIC,                             -- giới hạn vật lý, dùng cho QC range
    physical_max    NUMERIC,
    description     TEXT
);

INSERT INTO ref.parameters (parameter_code, name_vi, unit, category, physical_min, physical_max) VALUES
    ('PH',          'pH đất',                 'pH',      'SOIL_CHEM', 0,    14),
    ('EC',          'Độ dẫn điện',            'dS/m',    'SOIL_CHEM', 0,    20),
    ('MOISTURE',    'Độ ẩm đất',              '%',       'SOIL_PHYS', 0,    100),
    ('SOIL_TEMP',   'Nhiệt độ đất',           '°C',      'SOIL_PHYS', -10,  70),
    ('N',           'Đạm (N)',                'mg/kg',   'SOIL_CHEM', 0,    2000),
    ('P',           'Lân (P)',                'mg/kg',   'SOIL_CHEM', 0,    2000),
    ('K',           'Kali (K)',               'mg/kg',   'SOIL_CHEM', 0,    2000),
    ('OC',          'Cacbon hữu cơ',          '%',       'SOIL_CHEM', 0,    60),
    ('CEC',         'Dung tích hấp thu',      'cmol/kg', 'SOIL_CHEM', 0,    200),
    ('BULK_DENSITY','Dung trọng',             'g/cm3',   'SOIL_PHYS', 0.5,  2.5),
    ('MICROBIAL_C', 'Sinh khối vi sinh vật C','mg/kg',   'SOIL_BIO',  0,    5000),
    ('YIELD',       'Năng suất',              'kg/m2',   'PLANT',     0,    100);

-- >>>>> 01_iam.sql
-- =====================================================================
-- 01_iam.sql : người dùng, vai trò, tổ chức, quyền truy cập
-- =====================================================================

CREATE TABLE iam.organizations (
    organization_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code            VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    org_type        VARCHAR(32)  NOT NULL DEFAULT 'RESEARCH'
                    CHECK (org_type IN ('RESEARCH','UNIVERSITY','FARM','COMPANY','GOVERNMENT')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE iam.users (
    user_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID         REFERENCES iam.organizations(organization_id),
    username        VARCHAR(64)  NOT NULL UNIQUE,
    email           VARCHAR(255) NOT NULL UNIQUE,
    full_name       VARCHAR(255) NOT NULL,
    password_hash   TEXT,                                  -- chỉ lưu hash (bcrypt/argon2)
    is_active       BOOLEAN      NOT NULL DEFAULT true,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE iam.roles (
    role_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code       VARCHAR(32)  NOT NULL UNIQUE,         -- ADMIN, RESEARCHER, LAB_TECH, FIELD_TECH, DATA_ENGINEER, VIEWER
    name            VARCHAR(128) NOT NULL,
    description     TEXT
);

CREATE TABLE iam.permissions (
    permission_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    permission_code VARCHAR(64)  NOT NULL UNIQUE,         -- vd: iot.read, dataset.write, ota.deploy
    domain          VARCHAR(32)  NOT NULL,                -- trùng tên schema
    action          VARCHAR(16)  NOT NULL CHECK (action IN ('READ','WRITE','APPROVE','DEPLOY','ADMIN')),
    description     TEXT
);

CREATE TABLE iam.role_permissions (
    role_id         UUID NOT NULL REFERENCES iam.roles(role_id) ON DELETE CASCADE,
    permission_id   UUID NOT NULL REFERENCES iam.permissions(permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE iam.user_roles (
    user_id         UUID NOT NULL REFERENCES iam.users(user_id) ON DELETE CASCADE,
    role_id         UUID NOT NULL REFERENCES iam.roles(role_id) ON DELETE CASCADE,
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    granted_by      UUID REFERENCES iam.users(user_id),
    PRIMARY KEY (user_id, role_id)
);

-- API key cho tích hợp / Edge Gateway (màn hình 14). Chỉ lưu hash.
CREATE TABLE iam.api_keys (
    api_key_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_user_id   UUID REFERENCES iam.users(user_id),
    key_prefix      VARCHAR(16)  NOT NULL,                -- hiển thị dạng "ak_12ab…"
    key_hash        TEXT         NOT NULL UNIQUE,
    scopes          TEXT[]       NOT NULL DEFAULT '{}',
    expires_at      TIMESTAMPTZ,
    revoked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_organizations_updated BEFORE UPDATE ON iam.organizations
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON iam.users
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();

-- >>>>> 02_farm.sql
-- =====================================================================
-- 02_farm.sql : địa điểm, ô thí nghiệm, cây trồng, mùa vụ
-- =====================================================================

CREATE TABLE farm.sites (
    site_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID         REFERENCES iam.organizations(organization_id),
    site_code       VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    province        VARCHAR(128),
    district        VARCHAR(128),
    latitude        DECIMAL(9,6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude       DECIMAL(9,6) CHECK (longitude BETWEEN -180 AND 180),
    elevation_m     NUMERIC(7,2),
    climate_zone    VARCHAR(64),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE farm.plots (
    plot_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id         UUID         NOT NULL REFERENCES farm.sites(site_id),
    plot_code       VARCHAR(32)  NOT NULL,
    area_m2         NUMERIC(10,2) NOT NULL CHECK (area_m2 > 0),
    soil_type       VARCHAR(64)  NOT NULL,                 -- vd: Feralit, Phù sa, Xám bạc màu
    soil_texture    VARCHAR(64),
    latitude        DECIMAL(9,6) CHECK (latitude  BETWEEN -90  AND 90),
    longitude       DECIMAL(9,6) CHECK (longitude BETWEEN -180 AND 180),
    boundary_geojson JSONB,                                -- polygon cho bản đồ (màn hình 02)
    block_no        SMALLINT,                              -- khối lặp (RCBD)
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','FALLOW','INACTIVE','RETIRED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (site_id, plot_code)
);

CREATE TABLE farm.crops (
    crop_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    crop_code       VARCHAR(32)  NOT NULL UNIQUE,
    name_vi         VARCHAR(128) NOT NULL,
    scientific_name VARCHAR(128),
    variety         VARCHAR(128)
);

CREATE TABLE farm.crop_seasons (
    crop_season_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    crop_id         UUID         NOT NULL REFERENCES farm.crops(crop_id),
    season_code     VARCHAR(32)  NOT NULL,                 -- vd: 2026-XUAN
    planted_on      DATE         NOT NULL,
    harvested_on    DATE,
    planting_density NUMERIC(10,2),
    notes           TEXT,
    CHECK (harvested_on IS NULL OR harvested_on >= planted_on),
    UNIQUE (plot_id, season_code)
);

CREATE INDEX ix_plots_site ON farm.plots(site_id);
CREATE INDEX ix_crop_seasons_plot ON farm.crop_seasons(plot_id, planted_on);

CREATE TRIGGER trg_sites_updated BEFORE UPDATE ON farm.sites
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();
CREATE TRIGGER trg_plots_updated BEFORE UPDATE ON farm.plots
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();

-- >>>>> 03_biochar.sql
-- =====================================================================
-- 03_biochar.sql : phụ phẩm cây vải, lô biochar, nhiệt phân, làm giàu
-- (tạo trước experiment vì nghiệm thức tham chiếu lô biochar)
-- =====================================================================

CREATE TABLE biochar.feedstock_batches (
    feedstock_batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_code      VARCHAR(32)  NOT NULL UNIQUE,
    feedstock_type  VARCHAR(32)  NOT NULL DEFAULT 'LITCHI_PRUNING'
                    CHECK (feedstock_type IN ('LITCHI_PRUNING','LITCHI_BRANCH','LITCHI_LEAF','LITCHI_PEEL','LITCHI_SEED','MIXED','OTHER')),
    source_location VARCHAR(255),
    collected_on    DATE         NOT NULL,
    mass_kg         NUMERIC(10,2) NOT NULL CHECK (mass_kg > 0),
    moisture_pct    NUMERIC(5,2) CHECK (moisture_pct BETWEEN 0 AND 100),
    pretreatment    VARCHAR(255),                          -- phơi, băm, nghiền...
    notes           TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE biochar.biochar_batches (
    biochar_batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_code      VARCHAR(32)  NOT NULL UNIQUE,
    feedstock_batch_id UUID      NOT NULL REFERENCES biochar.feedstock_batches(feedstock_batch_id),
    produced_on     DATE         NOT NULL,
    -- thông số nhiệt phân
    reactor_type    VARCHAR(64),
    pyrolysis_temp_c NUMERIC(6,1) CHECK (pyrolysis_temp_c BETWEEN 200 AND 1000),
    residence_time_min NUMERIC(7,1) CHECK (residence_time_min > 0),
    heating_rate_c_min NUMERIC(6,2),
    input_mass_kg   NUMERIC(10,2) CHECK (input_mass_kg > 0),
    output_mass_kg  NUMERIC(10,2) CHECK (output_mass_kg >= 0),
    yield_pct       NUMERIC(5,2) GENERATED ALWAYS AS
                    (CASE WHEN input_mass_kg > 0 THEN round(output_mass_kg / input_mass_kg * 100, 2) END) STORED,
    -- chỉ tiêu chất lượng
    ph              NUMERIC(4,2) CHECK (ph BETWEEN 0 AND 14),
    ec_ds_m         NUMERIC(8,3),
    carbon_pct      NUMERIC(5,2) CHECK (carbon_pct BETWEEN 0 AND 100),
    ash_pct         NUMERIC(5,2) CHECK (ash_pct BETWEEN 0 AND 100),
    surface_area_m2_g NUMERIC(8,2),
    cec_cmol_kg     NUMERIC(8,2),
    -- an toàn: kim loại nặng, PAH ... {"Pb":1.2,"Cd":0.1,"As":0.5}
    heavy_metals_mg_kg JSONB,
    safety_status   VARCHAR(16)  NOT NULL DEFAULT 'PENDING'
                    CHECK (safety_status IN ('PENDING','PASSED','FAILED')),
    notes           TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (output_mass_kg IS NULL OR input_mass_kg IS NULL OR output_mass_kg <= input_mass_kg)
);

-- Làm giàu biochar (vi sinh, dinh dưỡng)
CREATE TABLE biochar.enrichment_batches (
    enrichment_batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_code      VARCHAR(32)  NOT NULL UNIQUE,
    biochar_batch_id UUID        NOT NULL REFERENCES biochar.biochar_batches(biochar_batch_id),
    enrichment_type VARCHAR(32)  NOT NULL
                    CHECK (enrichment_type IN ('MICROBIAL','NUTRIENT','COMPOST','MIXED')),
    microbial_formula VARCHAR(255),                        -- chủng / chế phẩm vi sinh
    nutrient_formula  VARCHAR(255),
    ratio_desc      VARCHAR(255),                          -- tỉ lệ phối trộn
    started_on      DATE         NOT NULL,
    finished_on     DATE,
    incubation_days INTEGER GENERATED ALWAYS AS (finished_on - started_on) STORED,
    notes           TEXT,
    CHECK (finished_on IS NULL OR finished_on >= started_on)
);

CREATE TABLE biochar.enrichment_results (
    enrichment_result_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    enrichment_batch_id UUID     NOT NULL REFERENCES biochar.enrichment_batches(enrichment_batch_id) ON DELETE CASCADE,
    parameter_code  VARCHAR(32)  NOT NULL,                 -- có thể là chỉ tiêu ngoài ref.parameters (vd CFU)
    value           NUMERIC      NOT NULL,
    unit            VARCHAR(32)  NOT NULL,
    measured_on     DATE         NOT NULL,
    method          VARCHAR(255),
    pass_flag       BOOLEAN
);

CREATE INDEX ix_biochar_batches_feedstock ON biochar.biochar_batches(feedstock_batch_id);
CREATE INDEX ix_enrichment_batches_biochar ON biochar.enrichment_batches(biochar_batch_id);

-- >>>>> 04_experiment.sql
-- =====================================================================
-- 04_experiment.sql : thí nghiệm, nghiệm thức, áp dụng lên ô, giai đoạn sinh trưởng
-- Quan hệ plot ↔ treatment đi qua treatment_applications (N–N theo thời gian).
-- =====================================================================

CREATE TABLE experiment.experiments (
    experiment_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id         UUID         NOT NULL REFERENCES farm.sites(site_id),
    experiment_code VARCHAR(32)  NOT NULL UNIQUE,
    title           VARCHAR(255) NOT NULL,
    design_type     VARCHAR(32)  NOT NULL DEFAULT 'RCBD'
                    CHECK (design_type IN ('CRD','RCBD','SPLIT_PLOT','FACTORIAL','OBSERVATIONAL')),
    replicates      SMALLINT     NOT NULL DEFAULT 3 CHECK (replicates > 0),
    started_on      DATE         NOT NULL,
    ended_on        DATE,
    principal_investigator UUID  REFERENCES iam.users(user_id),
    status          VARCHAR(16)  NOT NULL DEFAULT 'PLANNED'
                    CHECK (status IN ('PLANNED','RUNNING','COMPLETED','CANCELLED')),
    objective       TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (ended_on IS NULL OR ended_on >= started_on)
);

CREATE TABLE experiment.treatments (
    treatment_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id   UUID         NOT NULL REFERENCES experiment.experiments(experiment_id),
    treatment_code  VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    biochar_dose_kg_m2 NUMERIC(8,3) NOT NULL DEFAULT 0 CHECK (biochar_dose_kg_m2 >= 0),
    biochar_batch_id   UUID      REFERENCES biochar.biochar_batches(biochar_batch_id),
    enrichment_batch_id UUID     REFERENCES biochar.enrichment_batches(enrichment_batch_id),
    microbial_formula VARCHAR(255),
    fertilizer_desc VARCHAR(255),
    control_flag    BOOLEAN      NOT NULL DEFAULT false,
    description     TEXT,
    -- nghiệm thức đối chứng không bón biochar
    CHECK (NOT control_flag OR biochar_dose_kg_m2 = 0)
);

-- Áp dụng nghiệm thức lên ô (lặp lại, ngày bón, liều thực tế)
CREATE TABLE experiment.treatment_applications (
    application_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    treatment_id    UUID         NOT NULL REFERENCES experiment.treatments(treatment_id),
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    crop_season_id  UUID         REFERENCES farm.crop_seasons(crop_season_id),
    replicate_no    SMALLINT     NOT NULL DEFAULT 1,
    applied_on      DATE         NOT NULL,
    effective_from  TIMESTAMPTZ  NOT NULL,
    effective_to    TIMESTAMPTZ,                           -- NULL = đang hiệu lực
    actual_dose_kg_m2 NUMERIC(8,3) CHECK (actual_dose_kg_m2 >= 0),
    applied_by      UUID         REFERENCES iam.users(user_id),
    notes           TEXT,
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

-- Danh mục giai đoạn sinh trưởng theo cây trồng
CREATE TABLE experiment.growth_stages (
    growth_stage_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    crop_id         UUID         NOT NULL REFERENCES farm.crops(crop_id),
    stage_code      VARCHAR(32)  NOT NULL,                 -- vd: GERMINATION, VEGETATIVE, FLOWERING, FRUITING, HARVEST
    name_vi         VARCHAR(128) NOT NULL,
    stage_order     SMALLINT     NOT NULL,
    typical_days_from_planting INTEGER,
    UNIQUE (crop_id, stage_code),
    UNIQUE (crop_id, stage_order)
);

-- Ghi nhận giai đoạn thực tế trên từng ô / mùa vụ (để đồng bộ dữ liệu theo giai đoạn)
CREATE TABLE experiment.plot_growth_stages (
    plot_growth_stage_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    crop_season_id  UUID         NOT NULL REFERENCES farm.crop_seasons(crop_season_id),
    growth_stage_id UUID         NOT NULL REFERENCES experiment.growth_stages(growth_stage_id),
    started_at      TIMESTAMPTZ  NOT NULL,
    ended_at        TIMESTAMPTZ,
    observed_by     UUID         REFERENCES iam.users(user_id),
    CHECK (ended_at IS NULL OR ended_at > started_at),
    UNIQUE (crop_season_id, growth_stage_id)
);

CREATE INDEX ix_treatments_experiment ON experiment.treatments(experiment_id);
CREATE INDEX ix_treatment_app_plot_time ON experiment.treatment_applications(plot_id, effective_from);
CREATE INDEX ix_plot_growth_stage_time ON experiment.plot_growth_stages(crop_season_id, started_at);

CREATE TRIGGER trg_experiments_updated BEFORE UPDATE ON experiment.experiments
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();

-- ---------------------------------------------------------------------
-- Ngữ cảnh thí nghiệm của một ô tại một thời điểm:
-- nghiệm thức, liều biochar, loại đất, mùa vụ, giai đoạn sinh trưởng.
-- Dùng khi chuẩn hóa dữ liệu vào dataset.dataset_records.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION experiment.plot_context_at(p_plot_id UUID, p_at TIMESTAMPTZ)
RETURNS TABLE (
    plot_id UUID, site_id UUID, soil_type VARCHAR, treatment_id UUID,
    biochar_dose_kg_m2 NUMERIC, crop_season_id UUID, growth_stage_id UUID
)
LANGUAGE sql STABLE AS $$
    SELECT p.plot_id, p.site_id, p.soil_type,
           ta.treatment_id,
           COALESCE(ta.actual_dose_kg_m2, t.biochar_dose_kg_m2),
           cs.crop_season_id,
           pgs.growth_stage_id
    FROM farm.plots p
    LEFT JOIN LATERAL (
        SELECT * FROM experiment.treatment_applications a
        WHERE a.plot_id = p.plot_id
          AND a.effective_from <= p_at
          AND (a.effective_to IS NULL OR a.effective_to > p_at)
        ORDER BY a.effective_from DESC LIMIT 1
    ) ta ON true
    LEFT JOIN experiment.treatments t ON t.treatment_id = ta.treatment_id
    LEFT JOIN LATERAL (
        SELECT * FROM farm.crop_seasons c
        WHERE c.plot_id = p.plot_id
          AND c.planted_on <= p_at::date
          AND (c.harvested_on IS NULL OR c.harvested_on >= p_at::date)
        ORDER BY c.planted_on DESC LIMIT 1
    ) cs ON true
    LEFT JOIN LATERAL (
        SELECT * FROM experiment.plot_growth_stages g
        WHERE g.crop_season_id = cs.crop_season_id
          AND g.started_at <= p_at
          AND (g.ended_at IS NULL OR g.ended_at > p_at)
        ORDER BY g.started_at DESC LIMIT 1
    ) pgs ON true
    WHERE p.plot_id = p_plot_id;
$$;

-- >>>>> 05_iot.sql
-- =====================================================================
-- 05_iot.sql : Edge Gateway, Sensor Node, cảm biến, cấu hình, dữ liệu đọc
-- Kiến trúc theo hồ sơ: 03 Sensor Node + 01 Edge Gateway, LoRa/LoRaWAN,
-- chu kỳ đo 1–15 phút.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tiện ích: tạo partition theo tháng cho bảng partition theo RANGE thời gian
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ref.ensure_monthly_partitions(
    p_parent TEXT,          -- 'iot.sensor_readings'
    p_from   DATE,
    p_months INTEGER
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_schema TEXT := split_part(p_parent, '.', 1);
    v_table  TEXT := split_part(p_parent, '.', 2);
    v_start  DATE := date_trunc('month', p_from)::date;
    v_end    DATE;
    v_name   TEXT;
    v_count  INTEGER := 0;
BEGIN
    FOR i IN 0 .. p_months - 1 LOOP
        v_end  := (v_start + INTERVAL '1 month')::date;
        v_name := format('%s_%s', v_table, to_char(v_start, 'YYYYMM'));
        IF to_regclass(format('%I.%I', v_schema, v_name)) IS NULL THEN
            EXECUTE format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                           v_schema, v_name, v_schema, v_table, v_start, v_end);
            v_count := v_count + 1;
        END IF;
        v_start := v_end;
    END LOOP;
    RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------
-- Thiết bị
-- ---------------------------------------------------------------------
CREATE TABLE iot.gateways (
    gateway_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_id         UUID         NOT NULL REFERENCES farm.sites(site_id),
    gateway_code    VARCHAR(32)  NOT NULL UNIQUE,
    hardware_model  VARCHAR(128),                          -- vd: Raspberry Pi 5 / Jetson Nano
    serial_no       VARCHAR(64)  UNIQUE,
    firmware_version VARCHAR(32),
    current_model_version_id UUID,                         -- FK thêm ở 11_ml.sql
    lorawan_gateway_eui VARCHAR(32),
    network_backhaul VARCHAR(32) CHECK (network_backhaul IN ('4G','WIFI','ETHERNET','SATELLITE')),
    local_buffer_capacity_mb INTEGER,                      -- store-and-forward khi mất mạng
    latitude        DECIMAL(9,6),
    longitude       DECIMAL(9,6),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ONLINE'
                    CHECK (status IN ('ONLINE','OFFLINE','DEGRADED','MAINTENANCE','RETIRED')),
    last_seen_at    TIMESTAMPTZ,
    installed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE iot.sensor_nodes (
    node_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway_id      UUID         NOT NULL REFERENCES iot.gateways(gateway_id),
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    node_code       VARCHAR(32)  NOT NULL UNIQUE,
    dev_eui         VARCHAR(32)  UNIQUE,                   -- LoRaWAN DevEUI
    mcu_model       VARCHAR(64),
    firmware_version VARCHAR(32),
    power_source    VARCHAR(16)  CHECK (power_source IN ('BATTERY','SOLAR','MAINS')),
    sampling_interval_s INTEGER  NOT NULL DEFAULT 900
                    CHECK (sampling_interval_s BETWEEN 60 AND 900),   -- 1–15 phút
    battery_v       NUMERIC(4,2),
    latitude        DECIMAL(9,6),
    longitude       DECIMAL(9,6),
    status          VARCHAR(16)  NOT NULL DEFAULT 'ONLINE'
                    CHECK (status IN ('ONLINE','OFFLINE','LOW_BATTERY','FAULT','MAINTENANCE','RETIRED')),
    last_seen_at    TIMESTAMPTZ,
    installed_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Một cảm biến (đầu dò) có thể đo nhiều chỉ tiêu (vd đầu dò 7-in-1 pH/EC/ẩm/nhiệt/NPK)
CREATE TABLE iot.sensors (
    sensor_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id         UUID         NOT NULL REFERENCES iot.sensor_nodes(node_id),
    sensor_code     VARCHAR(32)  NOT NULL UNIQUE,
    sensor_model    VARCHAR(128),
    serial_no       VARCHAR(64),
    interface       VARCHAR(16)  CHECK (interface IN ('RS485','ANALOG','I2C','SDI12','UART')),
    measured_parameters VARCHAR(32)[] NOT NULL,            -- {'PH','EC','MOISTURE','N','P','K'}
    install_depth_cm NUMERIC(5,1),
    installed_at    TIMESTAMPTZ,
    removed_at      TIMESTAMPTZ,
    status          VARCHAR(16)  NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE','NEEDS_CALIBRATION','FAULT','REMOVED')),
    CHECK (removed_at IS NULL OR installed_at IS NULL OR removed_at > installed_at)
);

-- Cấu hình có phiên bản cho node/sensor (chu kỳ đo, ngưỡng tại edge, ...)
CREATE TABLE iot.sensor_configs (
    config_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    node_id         UUID         NOT NULL REFERENCES iot.sensor_nodes(node_id),
    sensor_id       UUID         REFERENCES iot.sensors(sensor_id),
    config_version  INTEGER      NOT NULL,
    sampling_interval_s INTEGER  NOT NULL CHECK (sampling_interval_s BETWEEN 60 AND 900),
    lora_spreading_factor SMALLINT CHECK (lora_spreading_factor BETWEEN 7 AND 12),
    tx_power_dbm    SMALLINT,
    edge_thresholds JSONB,                                 -- {"PH":{"min":5,"max":8}}
    valid_from      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    valid_to        TIMESTAMPTZ,
    applied_status  VARCHAR(16)  NOT NULL DEFAULT 'PENDING'
                    CHECK (applied_status IN ('PENDING','APPLIED','FAILED','SUPERSEDED')),
    created_by      UUID         REFERENCES iam.users(user_id),
    UNIQUE (node_id, config_version)
);

-- ---------------------------------------------------------------------
-- Dữ liệu đọc cảm biến (time-series, partition theo tháng)
-- PK phải chứa cột partition => (reading_id, measured_at)
-- ---------------------------------------------------------------------
CREATE SEQUENCE iot.sensor_readings_reading_id_seq AS BIGINT;

CREATE TABLE iot.sensor_readings (
    reading_id      BIGINT       NOT NULL DEFAULT nextval('iot.sensor_readings_reading_id_seq'),
    sensor_id       UUID         NOT NULL REFERENCES iot.sensors(sensor_id),
    node_id         UUID         NOT NULL REFERENCES iot.sensor_nodes(node_id),
    gateway_id      UUID         REFERENCES iot.gateways(gateway_id),
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    measured_at     TIMESTAMPTZ  NOT NULL,                 -- thời điểm đo tại node
    received_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),   -- thời điểm server nhận
    seq_no          BIGINT,                                -- số thứ tự gói từ node (phát hiện mất gói)
    ph              NUMERIC(5,2),
    ec              NUMERIC(8,3),                          -- dS/m
    soil_moisture   NUMERIC(5,2),                          -- %
    soil_temperature NUMERIC(5,2),                         -- °C
    n               NUMERIC(8,2),                          -- mg/kg
    p               NUMERIC(8,2),
    k               NUMERIC(8,2),
    battery_v       NUMERIC(4,2),
    rssi_dbm        SMALLINT,
    snr_db          NUMERIC(5,2),
    raw_payload     JSONB,                                 -- giá trị thô trước hiệu chuẩn
    calibration_applied BOOLEAN  NOT NULL DEFAULT false,
    quality_status  VARCHAR(16)  NOT NULL DEFAULT 'RAW'
                    CHECK (quality_status IN ('RAW','VALID','SUSPECT','INVALID','CORRECTED')),
    quality_flags   VARCHAR(32)[] NOT NULL DEFAULT '{}',   -- mã rule vi phạm
    timestamp_valid BOOLEAN,                               -- NULL = chưa kiểm
    PRIMARY KEY (reading_id, measured_at),
    UNIQUE (sensor_id, measured_at)                        -- chống trùng do gửi lại (store-and-forward)
) PARTITION BY RANGE (measured_at);

CREATE TABLE iot.sensor_readings_default PARTITION OF iot.sensor_readings DEFAULT;

CREATE INDEX ix_readings_plot_time   ON iot.sensor_readings (plot_id, measured_at);
CREATE INDEX ix_readings_sensor_time ON iot.sensor_readings (sensor_id, measured_at);
CREATE INDEX ix_readings_quality     ON iot.sensor_readings (quality_status, measured_at);

CREATE INDEX ix_nodes_gateway ON iot.sensor_nodes(gateway_id);
CREATE INDEX ix_nodes_plot    ON iot.sensor_nodes(plot_id);
CREATE INDEX ix_sensors_node  ON iot.sensors(node_id);

CREATE TRIGGER trg_gateways_updated BEFORE UPDATE ON iot.gateways
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();
CREATE TRIGGER trg_nodes_updated BEFORE UPDATE ON iot.sensor_nodes
    FOR EACH ROW EXECUTE FUNCTION ref.set_updated_at();

-- >>>>> 06_calibration.sql
-- =====================================================================
-- 06_calibration.sql : hiệu chuẩn cảm biến, thiết bị tham chiếu,
-- sai số, độ trôi, độ lặp lại
-- =====================================================================

CREATE TABLE calibration.reference_devices (
    reference_device_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_code     VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,                 -- vd: Máy đo pH để bàn, máy đo EC chuẩn
    manufacturer    VARCHAR(128),
    model           VARCHAR(128),
    parameters      VARCHAR(32)[] NOT NULL,
    certificate_no  VARCHAR(64),
    certified_until DATE
);

CREATE TABLE calibration.calibration_sessions (
    session_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sensor_id       UUID         NOT NULL REFERENCES iot.sensors(sensor_id),
    reference_device_id UUID     REFERENCES calibration.reference_devices(reference_device_id),
    session_type    VARCHAR(16)  NOT NULL DEFAULT 'LAB'
                    CHECK (session_type IN ('LAB','FIELD','DRIFT_CHECK','REPEATABILITY')),
    performed_at    TIMESTAMPTZ  NOT NULL,
    performed_by    UUID         REFERENCES iam.users(user_id),
    ambient_temp_c  NUMERIC(5,2),
    notes           TEXT
);

CREATE TABLE calibration.calibration_points (
    point_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID         NOT NULL REFERENCES calibration.calibration_sessions(session_id) ON DELETE CASCADE,
    parameter_code  VARCHAR(32)  NOT NULL REFERENCES ref.parameters(parameter_code),
    reference_value NUMERIC      NOT NULL,                 -- giá trị chuẩn
    sensor_value    NUMERIC      NOT NULL,                 -- giá trị cảm biến đọc
    replicate_no    SMALLINT     NOT NULL DEFAULT 1,
    measured_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Kết quả hiệu chuẩn: corrected = slope * raw + intercept
CREATE TABLE calibration.calibration_results (
    calibration_result_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id      UUID         NOT NULL REFERENCES calibration.calibration_sessions(session_id),
    sensor_id       UUID         NOT NULL REFERENCES iot.sensors(sensor_id),
    parameter_code  VARCHAR(32)  NOT NULL REFERENCES ref.parameters(parameter_code),
    n_points        INTEGER      NOT NULL,
    slope           NUMERIC      NOT NULL,
    intercept       NUMERIC      NOT NULL,
    r2              NUMERIC(6,5),
    rmse            NUMERIC,
    mae             NUMERIC,
    max_abs_error   NUMERIC,
    bias            NUMERIC,                               -- sai số hệ thống trung bình
    repeatability_cv_pct NUMERIC(7,3),                     -- độ lặp lại (CV%)
    drift_per_day   NUMERIC,                               -- độ trôi so với lần hiệu chuẩn trước
    tolerance       NUMERIC,                               -- sai số cho phép
    passed          BOOLEAN      NOT NULL,
    valid_from      TIMESTAMPTZ  NOT NULL,
    valid_to        TIMESTAMPTZ,
    is_active       BOOLEAN      NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE INDEX ix_cal_sessions_sensor ON calibration.calibration_sessions(sensor_id, performed_at);
CREATE INDEX ix_cal_points_session  ON calibration.calibration_points(session_id, parameter_code);
CREATE UNIQUE INDEX ux_cal_results_active
    ON calibration.calibration_results(sensor_id, parameter_code) WHERE is_active;

-- ---------------------------------------------------------------------
-- Tính kết quả hiệu chuẩn (hồi quy tuyến tính reference ~ sensor) cho một phiên.
-- Hệ số cũ của cùng sensor/chỉ tiêu bị vô hiệu, độ trôi tính so với bias cũ.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION calibration.compute_results(
    p_session_id UUID,
    p_tolerance  JSONB DEFAULT '{"PH":0.2,"EC":0.1,"MOISTURE":3,"N":20,"P":20,"K":20,"SOIL_TEMP":0.5}'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    r       RECORD;
    v_prev  calibration.calibration_results%ROWTYPE;
    v_tol   NUMERIC;
    v_count INTEGER := 0;
    v_sensor UUID;
    v_at    TIMESTAMPTZ;
BEGIN
    SELECT sensor_id, performed_at INTO v_sensor, v_at
    FROM calibration.calibration_sessions WHERE session_id = p_session_id;
    IF v_sensor IS NULL THEN
        RAISE EXCEPTION 'Không tìm thấy phiên hiệu chuẩn %', p_session_id;
    END IF;

    FOR r IN
        WITH fit AS (
            SELECT parameter_code,
                   count(*)                                   AS n,
                   regr_slope(reference_value, sensor_value)  AS slope,
                   regr_intercept(reference_value, sensor_value) AS intercept,
                   regr_r2(reference_value, sensor_value)     AS r2,
                   avg(sensor_value - reference_value)        AS bias
            FROM calibration.calibration_points
            WHERE session_id = p_session_id
            GROUP BY parameter_code
            HAVING count(*) >= 2
        ),
        err AS (
            SELECT p.parameter_code,
                   sqrt(avg(power(f.slope * p.sensor_value + f.intercept - p.reference_value, 2))) AS rmse,
                   avg(abs(f.slope * p.sensor_value + f.intercept - p.reference_value))           AS mae,
                   max(abs(f.slope * p.sensor_value + f.intercept - p.reference_value))           AS max_err
            FROM calibration.calibration_points p
            JOIN fit f USING (parameter_code)
            WHERE p.session_id = p_session_id
            GROUP BY p.parameter_code
        ),
        rep AS (   -- CV% của các lần lặp tại cùng điểm chuẩn
            SELECT parameter_code, avg(cv) AS cv
            FROM (
                SELECT parameter_code, reference_value,
                       stddev_samp(sensor_value) / NULLIF(abs(avg(sensor_value)), 0) * 100 AS cv
                FROM calibration.calibration_points
                WHERE session_id = p_session_id
                GROUP BY parameter_code, reference_value
                HAVING count(*) > 1
            ) x GROUP BY parameter_code
        )
        SELECT f.*, e.rmse, e.mae, e.max_err, rep.cv
        FROM fit f JOIN err e USING (parameter_code)
        LEFT JOIN rep USING (parameter_code)
    LOOP
        SELECT * INTO v_prev FROM calibration.calibration_results
        WHERE sensor_id = v_sensor AND parameter_code = r.parameter_code AND is_active;

        UPDATE calibration.calibration_results
        SET is_active = false, valid_to = v_at
        WHERE sensor_id = v_sensor AND parameter_code = r.parameter_code AND is_active;

        v_tol := (p_tolerance ->> r.parameter_code)::numeric;

        INSERT INTO calibration.calibration_results (
            session_id, sensor_id, parameter_code, n_points, slope, intercept, r2,
            rmse, mae, max_abs_error, bias, repeatability_cv_pct, drift_per_day,
            tolerance, passed, valid_from)
        VALUES (
            p_session_id, v_sensor, r.parameter_code, r.n, r.slope, r.intercept, r.r2,
            r.rmse, r.mae, r.max_err, r.bias, r.cv,
            CASE WHEN v_prev.calibration_result_id IS NOT NULL
                 THEN (r.bias - v_prev.bias)
                      / GREATEST(EXTRACT(EPOCH FROM v_at - v_prev.valid_from) / 86400, 1)
            END,
            v_tol,
            COALESCE(r.rmse <= v_tol, r.r2 >= 0.95),
            v_at);
        v_count := v_count + 1;
    END LOOP;
    RETURN v_count;
END;
$$;

-- Áp dụng hệ số hiệu chuẩn đang hiệu lực tại thời điểm đo
CREATE OR REPLACE FUNCTION calibration.apply(
    p_sensor_id UUID, p_parameter_code VARCHAR, p_raw NUMERIC, p_at TIMESTAMPTZ
) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT round(r.slope * p_raw + r.intercept, 3)
         FROM calibration.calibration_results r
         WHERE r.sensor_id = p_sensor_id
           AND r.parameter_code = p_parameter_code
           AND r.passed
           AND r.valid_from <= p_at
           AND (r.valid_to IS NULL OR r.valid_to > p_at)
         ORDER BY r.valid_from DESC LIMIT 1),
        p_raw);
$$;

-- >>>>> 07_laboratory.sql
-- =====================================================================
-- 07_laboratory.sql : mẫu đất / dung dịch, phương pháp, kết quả phân tích
-- =====================================================================

CREATE TABLE laboratory.lab_methods (
    method_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    method_code     VARCHAR(32)  NOT NULL UNIQUE,
    parameter_code  VARCHAR(32)  NOT NULL REFERENCES ref.parameters(parameter_code),
    name            VARCHAR(255) NOT NULL,
    standard_ref    VARCHAR(128),                          -- vd: TCVN 5979:2021
    instrument      VARCHAR(128),
    detection_limit NUMERIC,
    quantification_limit NUMERIC,
    unit            VARCHAR(32)  NOT NULL
);

CREATE TABLE laboratory.soil_samples (
    sample_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sample_code     VARCHAR(32)  NOT NULL UNIQUE,
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    sample_type     VARCHAR(16)  NOT NULL DEFAULT 'SOIL'
                    CHECK (sample_type IN ('SOIL','SOIL_SOLUTION','PLANT','BIOCHAR')),
    sampled_at      TIMESTAMPTZ  NOT NULL,                 -- để đồng bộ với dữ liệu cảm biến
    depth_from_cm   NUMERIC(5,1),
    depth_to_cm     NUMERIC(5,1),
    latitude        DECIMAL(9,6),
    longitude       DECIMAL(9,6),
    near_node_id    UUID         REFERENCES iot.sensor_nodes(node_id),   -- node gần nhất (đối chiếu sensor vs lab)
    composite_of    SMALLINT,                              -- số mẫu đơn gộp
    collected_by    UUID         REFERENCES iam.users(user_id),
    received_at     TIMESTAMPTZ,
    status          VARCHAR(16)  NOT NULL DEFAULT 'COLLECTED'
                    CHECK (status IN ('COLLECTED','RECEIVED','ANALYZING','COMPLETED','REJECTED')),
    notes           TEXT,
    CHECK (depth_to_cm IS NULL OR depth_from_cm IS NULL OR depth_to_cm > depth_from_cm)
);

CREATE TABLE laboratory.lab_results (
    lab_result_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sample_id       UUID         NOT NULL REFERENCES laboratory.soil_samples(sample_id) ON DELETE CASCADE,
    parameter_code  VARCHAR(32)  NOT NULL REFERENCES ref.parameters(parameter_code),
    value           NUMERIC      NOT NULL,
    unit            VARCHAR(32)  NOT NULL,
    method_id       UUID         REFERENCES laboratory.lab_methods(method_id),
    replicate_no    SMALLINT     NOT NULL DEFAULT 1,
    below_lod       BOOLEAN      NOT NULL DEFAULT false,
    analyzed_at     TIMESTAMPTZ,
    analyst_id      UUID         REFERENCES iam.users(user_id),
    approved_by     UUID         REFERENCES iam.users(user_id),
    result_status   VARCHAR(16)  NOT NULL DEFAULT 'DRAFT'
                    CHECK (result_status IN ('DRAFT','VERIFIED','APPROVED','REJECTED')),
    UNIQUE (sample_id, parameter_code, replicate_no)
);

CREATE INDEX ix_samples_plot_time   ON laboratory.soil_samples(plot_id, sampled_at);
CREATE INDEX ix_lab_results_sample  ON laboratory.lab_results(sample_id);
CREATE INDEX ix_lab_results_param   ON laboratory.lab_results(parameter_code);

-- ---------------------------------------------------------------------
-- Màn hình 07: đối chiếu cảm biến với phòng thí nghiệm
-- Lấy trung bình sensor hợp lệ trong ±2 giờ quanh thời điểm lấy mẫu.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW laboratory.v_sensor_vs_lab AS
WITH lab AS (
    SELECT s.sample_id, s.sample_code, s.plot_id, s.sampled_at,
           r.parameter_code, avg(r.value) AS lab_value
    FROM laboratory.soil_samples s
    JOIN laboratory.lab_results r ON r.sample_id = s.sample_id
    WHERE r.result_status IN ('VERIFIED','APPROVED')
      AND r.parameter_code IN ('PH','EC','MOISTURE','N','P','K')
    GROUP BY s.sample_id, s.sample_code, s.plot_id, s.sampled_at, r.parameter_code
)
SELECT lab.*,
       sen.sensor_value,
       sen.n_readings,
       sen.sensor_value - lab.lab_value AS diff,
       CASE WHEN lab.lab_value <> 0
            THEN round((sen.sensor_value - lab.lab_value) / abs(lab.lab_value) * 100, 2) END AS diff_pct
FROM lab
LEFT JOIN LATERAL (
    SELECT avg(CASE lab.parameter_code
                 WHEN 'PH' THEN sr.ph WHEN 'EC' THEN sr.ec WHEN 'MOISTURE' THEN sr.soil_moisture
                 WHEN 'N'  THEN sr.n  WHEN 'P'  THEN sr.p  WHEN 'K' THEN sr.k END) AS sensor_value,
           count(*) AS n_readings
    FROM iot.sensor_readings sr
    WHERE sr.plot_id = lab.plot_id
      AND sr.measured_at BETWEEN lab.sampled_at - INTERVAL '2 hours' AND lab.sampled_at + INTERVAL '2 hours'
      AND sr.quality_status IN ('VALID','CORRECTED')
) sen ON true;

-- >>>>> 08_data_quality.sql
-- =====================================================================
-- 08_data_quality.sql : luật QC, phiên kiểm tra, lỗi dữ liệu, audit lineage
-- + hàm nạp dữ liệu cảm biến và hàm chạy QC
-- =====================================================================

CREATE TABLE data_quality.quality_rules (
    rule_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rule_code       VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    target          VARCHAR(32)  NOT NULL DEFAULT 'SENSOR_READING'
                    CHECK (target IN ('SENSOR_READING','LAB_RESULT','DATASET_RECORD')),
    rule_type       VARCHAR(32)  NOT NULL
                    CHECK (rule_type IN ('RANGE','RATE_OF_CHANGE','FLATLINE','TIMESTAMP','DUPLICATE','MISSING','CROSS_CHECK')),
    parameter_code  VARCHAR(32)  REFERENCES ref.parameters(parameter_code),
    min_value       NUMERIC,
    max_value       NUMERIC,
    max_delta       NUMERIC,                               -- RATE_OF_CHANGE: chênh lệch tối đa giữa 2 lần đo liên tiếp
    window_minutes  INTEGER,                               -- FLATLINE / MISSING
    severity        VARCHAR(8)   NOT NULL DEFAULT 'ERROR' CHECK (severity IN ('WARN','ERROR')),
    is_active       BOOLEAN      NOT NULL DEFAULT true,
    description     TEXT,
    CHECK (rule_type <> 'RANGE' OR (parameter_code IS NOT NULL AND min_value IS NOT NULL AND max_value IS NOT NULL)),
    CHECK (rule_type <> 'RATE_OF_CHANGE' OR (parameter_code IS NOT NULL AND max_delta IS NOT NULL))
);

-- Một lần chạy QC trên một khoảng thời gian
CREATE TABLE data_quality.quality_checks (
    check_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target          VARCHAR(32)  NOT NULL DEFAULT 'SENSOR_READING',
    scope_from      TIMESTAMPTZ  NOT NULL,
    scope_to        TIMESTAMPTZ  NOT NULL,
    started_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    finished_at     TIMESTAMPTZ,
    records_checked INTEGER      NOT NULL DEFAULT 0,
    records_valid   INTEGER      NOT NULL DEFAULT 0,
    records_suspect INTEGER      NOT NULL DEFAULT 0,
    records_invalid INTEGER      NOT NULL DEFAULT 0,
    pass_rate_pct   NUMERIC(6,2) GENERATED ALWAYS AS
                    (CASE WHEN records_checked > 0 THEN round(records_valid * 100.0 / records_checked, 2) END) STORED,
    triggered_by    UUID         REFERENCES iam.users(user_id),
    status          VARCHAR(16)  NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','DONE','FAILED')),
    CHECK (scope_to > scope_from)
);

CREATE TABLE data_quality.data_issues (
    issue_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_id        UUID         REFERENCES data_quality.quality_checks(check_id),
    rule_id         UUID         REFERENCES data_quality.quality_rules(rule_id),
    issue_type      VARCHAR(32)  NOT NULL
                    CHECK (issue_type IN ('OUT_OF_RANGE','SPIKE','FLATLINE','MISSING','DUPLICATE',
                                          'INVALID_TIMESTAMP','SENSOR_FAULT','LAB_MISMATCH','OTHER')),
    source_table    VARCHAR(64)  NOT NULL,                 -- 'iot.sensor_readings'
    source_record_id VARCHAR(64),
    sensor_id       UUID         REFERENCES iot.sensors(sensor_id),
    plot_id         UUID         REFERENCES farm.plots(plot_id),
    observed_at     TIMESTAMPTZ,
    parameter_code  VARCHAR(32),
    observed_value  NUMERIC,
    details         JSONB,
    severity        VARCHAR(8)   NOT NULL DEFAULT 'ERROR' CHECK (severity IN ('WARN','ERROR')),
    status          VARCHAR(16)  NOT NULL DEFAULT 'OPEN'
                    CHECK (status IN ('OPEN','CONFIRMED','CORRECTED','IGNORED')),
    detected_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    resolved_by     UUID         REFERENCES iam.users(user_id),
    resolved_at     TIMESTAMPTZ
);

-- Lineage: mọi thao tác làm sạch / loại bỏ / sửa bản ghi trước khi vào SQI/ML
CREATE TABLE data_quality.data_audit (
    audit_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dataset_id      UUID,                                  -- FK thêm ở 09_dataset.sql
    source_table    VARCHAR(64)  NOT NULL,
    record_id       VARCHAR(64)  NOT NULL,
    action          VARCHAR(16)  NOT NULL CHECK (action IN ('CREATE','UPDATE','REJECT','CLEAN','RESTORE')),
    reason          TEXT,
    old_value       JSONB,
    new_value       JSONB,
    actor_id        UUID,                                  -- user hoặc NULL = hệ thống
    actor_type      VARCHAR(16)  NOT NULL DEFAULT 'SYSTEM' CHECK (actor_type IN ('USER','SYSTEM','GATEWAY')),
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ix_issues_time     ON data_quality.data_issues(observed_at);
CREATE INDEX ix_issues_status   ON data_quality.data_issues(status, issue_type);
CREATE INDEX ix_issues_sensor   ON data_quality.data_issues(sensor_id, observed_at);
CREATE INDEX ix_data_audit_rec  ON data_quality.data_audit(source_table, record_id);
CREATE INDEX ix_data_audit_ds   ON data_quality.data_audit(dataset_id, occurred_at);

-- ---------------------------------------------------------------------
-- Ánh xạ mã chỉ tiêu -> cột trong iot.sensor_readings
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iot.reading_column(p_parameter_code VARCHAR)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_parameter_code
        WHEN 'PH'        THEN 'ph'
        WHEN 'EC'        THEN 'ec'
        WHEN 'MOISTURE'  THEN 'soil_moisture'
        WHEN 'SOIL_TEMP' THEN 'soil_temperature'
        WHEN 'N'         THEN 'n'
        WHEN 'P'         THEN 'p'
        WHEN 'K'         THEN 'k'
    END;
$$;

-- ---------------------------------------------------------------------
-- Nạp 1 bản tin từ Edge Gateway.
-- p_raw: {"PH":6.1,"EC":0.42,"MOISTURE":31.5,"SOIL_TEMP":27.1,"N":45,"P":18,"K":120}
-- Áp dụng hệ số hiệu chuẩn, chống trùng; bản tin trùng được ghi vào data_issues.
-- Trả về reading_id, hoặc NULL nếu trùng.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION iot.ingest_reading(
    p_sensor_id   UUID,
    p_measured_at TIMESTAMPTZ,
    p_raw         JSONB,
    p_seq_no      BIGINT DEFAULT NULL,
    p_battery_v   NUMERIC DEFAULT NULL,
    p_rssi_dbm    SMALLINT DEFAULT NULL,
    p_snr_db      NUMERIC DEFAULT NULL,
    p_received_at TIMESTAMPTZ DEFAULT now()
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_node    iot.sensor_nodes%ROWTYPE;
    v_id      BIGINT;
    v_has_cal BOOLEAN;
BEGIN
    SELECT n.* INTO v_node
    FROM iot.sensors s JOIN iot.sensor_nodes n ON n.node_id = s.node_id
    WHERE s.sensor_id = p_sensor_id;
    IF v_node.node_id IS NULL THEN
        RAISE EXCEPTION 'Sensor % không tồn tại', p_sensor_id;
    END IF;

    SELECT EXISTS (SELECT 1 FROM calibration.calibration_results
                   WHERE sensor_id = p_sensor_id AND passed
                     AND valid_from <= p_measured_at
                     AND (valid_to IS NULL OR valid_to > p_measured_at))
      INTO v_has_cal;

    INSERT INTO iot.sensor_readings (
        sensor_id, node_id, gateway_id, plot_id, measured_at, received_at, seq_no,
        ph, ec, soil_moisture, soil_temperature, n, p, k,
        battery_v, rssi_dbm, snr_db, raw_payload, calibration_applied)
    VALUES (
        p_sensor_id, v_node.node_id, v_node.gateway_id, v_node.plot_id, p_measured_at, p_received_at, p_seq_no,
        calibration.apply(p_sensor_id, 'PH',        (p_raw->>'PH')::numeric,        p_measured_at),
        calibration.apply(p_sensor_id, 'EC',        (p_raw->>'EC')::numeric,        p_measured_at),
        calibration.apply(p_sensor_id, 'MOISTURE',  (p_raw->>'MOISTURE')::numeric,  p_measured_at),
        calibration.apply(p_sensor_id, 'SOIL_TEMP', (p_raw->>'SOIL_TEMP')::numeric, p_measured_at),
        calibration.apply(p_sensor_id, 'N',         (p_raw->>'N')::numeric,         p_measured_at),
        calibration.apply(p_sensor_id, 'P',         (p_raw->>'P')::numeric,         p_measured_at),
        calibration.apply(p_sensor_id, 'K',         (p_raw->>'K')::numeric,         p_measured_at),
        p_battery_v, p_rssi_dbm, p_snr_db, p_raw, v_has_cal)
    ON CONFLICT (sensor_id, measured_at) DO NOTHING
    RETURNING reading_id INTO v_id;

    IF v_id IS NULL THEN
        INSERT INTO data_quality.data_issues
            (issue_type, source_table, sensor_id, plot_id, observed_at, details, severity)
        VALUES ('DUPLICATE', 'iot.sensor_readings', p_sensor_id, v_node.plot_id, p_measured_at,
                jsonb_build_object('seq_no', p_seq_no, 'payload', p_raw), 'WARN');
    END IF;

    UPDATE iot.sensor_nodes
    SET last_seen_at = GREATEST(COALESCE(last_seen_at, p_received_at), p_received_at),
        battery_v    = COALESCE(p_battery_v, battery_v)
    WHERE node_id = v_node.node_id;

    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Chạy QC cho dữ liệu cảm biến trong [p_from, p_to):
--   1. timestamp hợp lệ (không ở tương lai, không trễ quá p_max_delay)
--   2. RANGE / RATE_OF_CHANGE theo quality_rules
--   3. gán quality_status: INVALID (vi phạm ERROR), SUSPECT (WARN), VALID
-- Bản ghi đã CORRECTED (sửa tay) không bị ghi đè.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION data_quality.run_sensor_checks(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ,
    p_max_delay INTERVAL DEFAULT INTERVAL '7 days',
    p_user UUID DEFAULT NULL
) RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE
    v_check UUID;
    r       RECORD;
    v_col   TEXT;
BEGIN
    INSERT INTO data_quality.quality_checks (scope_from, scope_to, triggered_by)
    VALUES (p_from, p_to, p_user) RETURNING check_id INTO v_check;

    -- reset cờ của lần chạy trước trong phạm vi
    UPDATE iot.sensor_readings
    SET quality_flags = '{}'
    WHERE measured_at >= p_from AND measured_at < p_to AND quality_status <> 'CORRECTED';

    -- 1. timestamp
    UPDATE iot.sensor_readings
    SET timestamp_valid = (measured_at <= received_at + INTERVAL '5 minutes'
                           AND measured_at >= received_at - p_max_delay),
        quality_flags = CASE WHEN measured_at <= received_at + INTERVAL '5 minutes'
                                  AND measured_at >= received_at - p_max_delay
                             THEN quality_flags ELSE array_append(quality_flags, 'TS_INVALID') END
    WHERE measured_at >= p_from AND measured_at < p_to AND quality_status <> 'CORRECTED';

    INSERT INTO data_quality.data_issues
        (check_id, issue_type, source_table, source_record_id, sensor_id, plot_id, observed_at, details, severity)
    SELECT v_check, 'INVALID_TIMESTAMP', 'iot.sensor_readings', reading_id::text, sensor_id, plot_id, measured_at,
           jsonb_build_object('received_at', received_at), 'ERROR'
    FROM iot.sensor_readings
    WHERE measured_at >= p_from AND measured_at < p_to AND timestamp_valid = false;

    -- 2. RANGE
    FOR r IN SELECT * FROM data_quality.quality_rules
             WHERE is_active AND target = 'SENSOR_READING' AND rule_type = 'RANGE' LOOP
        v_col := iot.reading_column(r.parameter_code);
        CONTINUE WHEN v_col IS NULL;
        EXECUTE format($q$
            WITH bad AS (
                UPDATE iot.sensor_readings
                SET quality_flags = array_append(quality_flags, %L)
                WHERE measured_at >= $1 AND measured_at < $2
                  AND quality_status <> 'CORRECTED'
                  AND %I IS NOT NULL AND (%I < $3 OR %I > $4)
                RETURNING reading_id, sensor_id, plot_id, measured_at, %I AS v
            )
            INSERT INTO data_quality.data_issues
                (check_id, rule_id, issue_type, source_table, source_record_id, sensor_id, plot_id,
                 observed_at, parameter_code, observed_value, severity, details)
            SELECT $5, $6, 'OUT_OF_RANGE', 'iot.sensor_readings', reading_id::text, sensor_id, plot_id,
                   measured_at, %L, v, %L, jsonb_build_object('min', $3, 'max', $4)
            FROM bad $q$,
            r.rule_code, v_col, v_col, v_col, v_col, r.parameter_code, r.severity)
        USING p_from, p_to, r.min_value, r.max_value, v_check, r.rule_id;
    END LOOP;

    -- 2b. RATE_OF_CHANGE (spike) so với lần đo trước của cùng sensor
    FOR r IN SELECT * FROM data_quality.quality_rules
             WHERE is_active AND target = 'SENSOR_READING' AND rule_type = 'RATE_OF_CHANGE' LOOP
        v_col := iot.reading_column(r.parameter_code);
        CONTINUE WHEN v_col IS NULL;
        EXECUTE format($q$
            WITH d AS (
                SELECT reading_id, measured_at, sensor_id, plot_id, %I AS v,
                       %I - lag(%I) OVER (PARTITION BY sensor_id ORDER BY measured_at) AS delta
                FROM iot.sensor_readings
                WHERE measured_at >= $1 - INTERVAL '1 day' AND measured_at < $2
            ),
            bad AS (
                UPDATE iot.sensor_readings sr
                SET quality_flags = array_append(sr.quality_flags, %L)
                FROM d
                WHERE sr.reading_id = d.reading_id AND sr.measured_at = d.measured_at
                  AND d.measured_at >= $1 AND abs(d.delta) > $3
                  AND sr.quality_status <> 'CORRECTED'
                RETURNING d.reading_id, d.sensor_id, d.plot_id, d.measured_at, d.v, d.delta
            )
            INSERT INTO data_quality.data_issues
                (check_id, rule_id, issue_type, source_table, source_record_id, sensor_id, plot_id,
                 observed_at, parameter_code, observed_value, severity, details)
            SELECT $4, $5, 'SPIKE', 'iot.sensor_readings', reading_id::text, sensor_id, plot_id,
                   measured_at, %L, v, %L, jsonb_build_object('delta', delta, 'max_delta', $3)
            FROM bad $q$,
            v_col, v_col, v_col, r.rule_code, r.parameter_code, r.severity)
        USING p_from, p_to, r.max_delta, v_check, r.rule_id;
    END LOOP;

    -- 3. gán trạng thái
    UPDATE iot.sensor_readings sr
    SET quality_status = CASE
            WHEN 'TS_INVALID' = ANY(sr.quality_flags) THEN 'INVALID'
            WHEN EXISTS (SELECT 1 FROM data_quality.quality_rules q
                         WHERE q.rule_code = ANY(sr.quality_flags) AND q.severity = 'ERROR') THEN 'INVALID'
            WHEN cardinality(sr.quality_flags) > 0 THEN 'SUSPECT'
            ELSE 'VALID' END
    WHERE sr.measured_at >= p_from AND sr.measured_at < p_to AND sr.quality_status <> 'CORRECTED';

    -- lineage cho bản ghi bị loại
    INSERT INTO data_quality.data_audit (source_table, record_id, action, reason, new_value)
    SELECT 'iot.sensor_readings', reading_id::text, 'REJECT',
           'QC check ' || v_check, jsonb_build_object('flags', quality_flags)
    FROM iot.sensor_readings
    WHERE measured_at >= p_from AND measured_at < p_to AND quality_status = 'INVALID';

    UPDATE data_quality.quality_checks c
    SET finished_at = now(), status = 'DONE',
        records_checked = s.total, records_valid = s.valid,
        records_suspect = s.suspect, records_invalid = s.invalid
    FROM (
        SELECT count(*) AS total,
               count(*) FILTER (WHERE quality_status IN ('VALID','CORRECTED')) AS valid,
               count(*) FILTER (WHERE quality_status = 'SUSPECT') AS suspect,
               count(*) FILTER (WHERE quality_status = 'INVALID') AS invalid
        FROM iot.sensor_readings
        WHERE measured_at >= p_from AND measured_at < p_to
    ) s
    WHERE c.check_id = v_check;

    RETURN v_check;
END;
$$;

-- >>>>> 09_dataset.sql
-- =====================================================================
-- 09_dataset.sql : dataset tham chiếu, phiên bản, bản ghi chuẩn hóa, nhãn,
-- chia train/val/test có kiểm soát leakage
-- =====================================================================

CREATE TABLE dataset.labels (
    label_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    label_set       VARCHAR(32)  NOT NULL DEFAULT 'SOIL_HEALTH',
    label_code      VARCHAR(32)  NOT NULL,                 -- VERY_GOOD, GOOD, FAIR, POOR
    name_vi         VARCHAR(128) NOT NULL,
    class_order     SMALLINT     NOT NULL,
    description     TEXT,
    UNIQUE (label_set, label_code)
);

CREATE TABLE dataset.datasets (
    dataset_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_code    VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    purpose         VARCHAR(16)  NOT NULL DEFAULT 'REFERENCE'
                    CHECK (purpose IN ('REFERENCE','TRAINING','EVALUATION','FIELD_TEST')),
    site_id         UUID         REFERENCES farm.sites(site_id),
    experiment_id   UUID         REFERENCES experiment.experiments(experiment_id),
    owner_id        UUID         REFERENCES iam.users(user_id),
    min_valid_observations INTEGER NOT NULL DEFAULT 10000,  -- yêu cầu hồ sơ
    description     TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE dataset.dataset_versions (
    dataset_version_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_id      UUID         NOT NULL REFERENCES dataset.datasets(dataset_id),
    version_no      INTEGER      NOT NULL,
    status          VARCHAR(16)  NOT NULL DEFAULT 'DRAFT'
                    CHECK (status IN ('DRAFT','BUILT','FROZEN','DEPRECATED')),
    time_from       TIMESTAMPTZ  NOT NULL,
    time_to         TIMESTAMPTZ  NOT NULL,
    aggregation     VARCHAR(16)  NOT NULL DEFAULT 'RAW' CHECK (aggregation IN ('RAW','HOURLY','DAILY')),
    split_strategy  VARCHAR(16)  NOT NULL DEFAULT 'BY_TIME'
                    CHECK (split_strategy IN ('RANDOM','BY_PLOT','BY_TIME','BY_BLOCK')),
    split_ratio     JSONB        NOT NULL DEFAULT '{"TRAIN":0.7,"VAL":0.15,"TEST":0.15}',
    random_seed     INTEGER      NOT NULL DEFAULT 42,
    record_count    INTEGER,
    valid_count     INTEGER,
    labeled_count   INTEGER,
    checksum        TEXT,                                  -- md5 tập record_id khi FROZEN
    created_by      UUID         REFERENCES iam.users(user_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    frozen_at       TIMESTAMPTZ,
    notes           TEXT,
    UNIQUE (dataset_id, version_no),
    CHECK (time_to > time_from)
);

-- Bản ghi quan sát đã đồng bộ: thời gian + vị trí + nghiệm thức + loại đất
-- + liều biochar + giai đoạn sinh trưởng + sensor + lab + nhãn
CREATE TABLE dataset.dataset_records (
    record_id       UUID         NOT NULL DEFAULT gen_random_uuid(),
    dataset_version_id UUID      NOT NULL REFERENCES dataset.dataset_versions(dataset_version_id) ON DELETE CASCADE,
    observed_at     TIMESTAMPTZ  NOT NULL,
    site_id         UUID         REFERENCES farm.sites(site_id),
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    treatment_id    UUID         REFERENCES experiment.treatments(treatment_id),
    soil_type       VARCHAR(64),
    biochar_dose_kg_m2 NUMERIC(8,3),
    crop_season_id  UUID         REFERENCES farm.crop_seasons(crop_season_id),
    growth_stage_id UUID         REFERENCES experiment.growth_stages(growth_stage_id),
    -- đặc trưng dùng thường xuyên: cột riêng (không để trong JSONB)
    ph              NUMERIC(5,2),
    ec              NUMERIC(8,3),
    soil_moisture   NUMERIC(5,2),
    soil_temperature NUMERIC(5,2),
    n               NUMERIC(8,2),
    p               NUMERIC(8,2),
    k               NUMERIC(8,2),
    sensor_payload  JSONB,                                 -- chỉ tiêu phụ / thống kê cửa sổ
    lab_payload     JSONB,                                 -- {"OC":1.8,"CEC":12.4,...} kết quả lab gần nhất
    source_reading_ids BIGINT[],
    source_lab_result_ids UUID[],
    label_id        UUID         REFERENCES dataset.labels(label_id),
    label_source    VARCHAR(16)  CHECK (label_source IN ('SQI_RULE','EXPERT','LAB')),
    split           VARCHAR(8)   CHECK (split IN ('TRAIN','VAL','TEST')),
    group_key       VARCHAR(128),                          -- nhóm dùng để chia (chống leakage)
    valid_flag      BOOLEAN      NOT NULL DEFAULT false,
    invalid_reason  VARCHAR(255),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    PRIMARY KEY (record_id, observed_at),
    UNIQUE (dataset_version_id, plot_id, observed_at)
) PARTITION BY RANGE (observed_at);

CREATE TABLE dataset.dataset_records_default PARTITION OF dataset.dataset_records DEFAULT;

CREATE INDEX ix_records_plot_time    ON dataset.dataset_records (plot_id, observed_at);
CREATE INDEX ix_records_version      ON dataset.dataset_records (dataset_version_id, split);
CREATE INDEX ix_records_treatment    ON dataset.dataset_records (treatment_id, observed_at);

ALTER TABLE data_quality.data_audit
    ADD CONSTRAINT fk_data_audit_dataset FOREIGN KEY (dataset_id) REFERENCES dataset.datasets(dataset_id);

-- Không cho sửa bản ghi của version đã FROZEN
CREATE OR REPLACE FUNCTION dataset.guard_frozen()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_status VARCHAR;
BEGIN
    SELECT status INTO v_status FROM dataset.dataset_versions
    WHERE dataset_version_id = COALESCE(NEW.dataset_version_id, OLD.dataset_version_id);
    IF v_status = 'FROZEN' THEN
        RAISE EXCEPTION 'Dataset version % đã FROZEN, không thể thay đổi',
            COALESCE(NEW.dataset_version_id, OLD.dataset_version_id);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER trg_records_guard_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON dataset.dataset_records
    FOR EACH ROW EXECUTE FUNCTION dataset.guard_frozen();

-- ---------------------------------------------------------------------
-- Xây dựng bản ghi cho 1 dataset version từ sensor (đã QC) + lab + ngữ cảnh thí nghiệm
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dataset.build_version(p_version_id UUID)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v  dataset.dataset_versions%ROWTYPE;
    v_bucket TEXT;
    v_rows INTEGER;
    v_train NUMERIC;
    v_val   NUMERIC;
BEGIN
    SELECT * INTO v FROM dataset.dataset_versions WHERE dataset_version_id = p_version_id;
    IF v.dataset_version_id IS NULL THEN
        RAISE EXCEPTION 'Dataset version % không tồn tại', p_version_id;
    END IF;
    IF v.status = 'FROZEN' THEN
        RAISE EXCEPTION 'Dataset version % đã FROZEN', p_version_id;
    END IF;

    DELETE FROM dataset.dataset_records WHERE dataset_version_id = p_version_id;

    v_bucket := CASE v.aggregation WHEN 'HOURLY' THEN 'hour' WHEN 'DAILY' THEN 'day' END;
    v_train  := (v.split_ratio->>'TRAIN')::numeric;
    v_val    := (v.split_ratio->>'VAL')::numeric;

    INSERT INTO dataset.dataset_records (
        dataset_version_id, observed_at, site_id, plot_id, treatment_id, soil_type,
        biochar_dose_kg_m2, crop_season_id, growth_stage_id,
        ph, ec, soil_moisture, soil_temperature, n, p, k,
        sensor_payload, lab_payload, source_reading_ids, source_lab_result_ids,
        group_key, valid_flag, invalid_reason)
    WITH obs AS (
        SELECT sr.plot_id,
               CASE WHEN v_bucket IS NULL THEN sr.measured_at
                    ELSE date_trunc(v_bucket, sr.measured_at) END AS observed_at,
               avg(sr.ph) ph, avg(sr.ec) ec, avg(sr.soil_moisture) soil_moisture,
               avg(sr.soil_temperature) soil_temperature,
               avg(sr.n) n, avg(sr.p) p, avg(sr.k) k,
               count(*) n_readings,
               array_agg(sr.reading_id ORDER BY sr.measured_at) reading_ids
        FROM iot.sensor_readings sr
        WHERE sr.measured_at >= v.time_from AND sr.measured_at < v.time_to
          AND sr.quality_status IN ('VALID','CORRECTED')
        GROUP BY 1, 2
    )
    SELECT p_version_id, o.observed_at, ctx.site_id, o.plot_id, ctx.treatment_id, ctx.soil_type,
           ctx.biochar_dose_kg_m2, ctx.crop_season_id, ctx.growth_stage_id,
           round(o.ph, 2), round(o.ec, 3), round(o.soil_moisture, 2), round(o.soil_temperature, 2),
           round(o.n, 2), round(o.p, 2), round(o.k, 2),
           jsonb_build_object('n_readings', o.n_readings),
           lab.payload, o.reading_ids, lab.ids,
           CASE v.split_strategy
                WHEN 'BY_PLOT'  THEN o.plot_id::text
                WHEN 'BY_BLOCK' THEN COALESCE(pl.block_no::text, o.plot_id::text)
                WHEN 'BY_TIME'  THEN to_char(o.observed_at, 'IYYY-IW')    -- khối theo tuần
                ELSE gen_random_uuid()::text END,
           (o.ph IS NOT NULL AND o.ec IS NOT NULL AND o.soil_moisture IS NOT NULL
            AND o.n IS NOT NULL AND o.p IS NOT NULL AND o.k IS NOT NULL AND ctx.treatment_id IS NOT NULL),
           CASE WHEN ctx.treatment_id IS NULL THEN 'Không xác định nghiệm thức'
                WHEN o.ph IS NULL OR o.ec IS NULL OR o.soil_moisture IS NULL
                  OR o.n IS NULL OR o.p IS NULL OR o.k IS NULL THEN 'Thiếu chỉ tiêu cảm biến' END
    FROM obs o
    JOIN farm.plots pl ON pl.plot_id = o.plot_id
    CROSS JOIN LATERAL experiment.plot_context_at(o.plot_id, o.observed_at) ctx
    LEFT JOIN LATERAL (   -- kết quả lab gần nhất trong ±7 ngày
        SELECT jsonb_object_agg(x.parameter_code, x.value) AS payload,
               array_agg(x.lab_result_id) AS ids
        FROM (
            SELECT DISTINCT ON (r.parameter_code) r.parameter_code, r.value, r.lab_result_id
            FROM laboratory.soil_samples s
            JOIN laboratory.lab_results r ON r.sample_id = s.sample_id
            WHERE s.plot_id = o.plot_id
              AND r.result_status IN ('VERIFIED','APPROVED')
              AND s.sampled_at BETWEEN o.observed_at - INTERVAL '7 days' AND o.observed_at + INTERVAL '7 days'
            ORDER BY r.parameter_code, abs(EXTRACT(EPOCH FROM s.sampled_at - o.observed_at))
        ) x
    ) lab ON true;

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    -- Chia tập theo group_key (cả nhóm vào cùng 1 tập => không leakage giữa các tập).
    -- BY_TIME: các tuần đầu -> TRAIN, kế tiếp -> VAL, cuối -> TEST (không nhìn tương lai).
    IF v.split_strategy = 'BY_TIME' THEN
        UPDATE dataset.dataset_records r
        SET split = CASE WHEN g.pos <= v_train THEN 'TRAIN'
                         WHEN g.pos <= v_train + v_val THEN 'VAL' ELSE 'TEST' END
        FROM (
            SELECT group_key, cume_dist() OVER (ORDER BY group_key) AS pos
            FROM (SELECT DISTINCT group_key FROM dataset.dataset_records
                  WHERE dataset_version_id = p_version_id) k
        ) g
        WHERE r.dataset_version_id = p_version_id AND r.group_key = g.group_key;
    ELSE
        UPDATE dataset.dataset_records r
        SET split = CASE WHEN h.u < v_train THEN 'TRAIN'
                         WHEN h.u < v_train + v_val THEN 'VAL' ELSE 'TEST' END
        FROM (
            SELECT group_key,
                   ((hashtext(group_key || ':' || v.random_seed)::bigint + 2147483648) % 10000) / 10000.0 AS u
            FROM (SELECT DISTINCT group_key FROM dataset.dataset_records
                  WHERE dataset_version_id = p_version_id) k
        ) h
        WHERE r.dataset_version_id = p_version_id AND r.group_key = h.group_key;
    END IF;

    UPDATE dataset.dataset_versions dv
    SET status = 'BUILT',
        record_count = s.total, valid_count = s.valid, labeled_count = s.labeled
    FROM (
        SELECT count(*) total,
               count(*) FILTER (WHERE valid_flag) valid,
               count(*) FILTER (WHERE label_id IS NOT NULL) labeled
        FROM dataset.dataset_records WHERE dataset_version_id = p_version_id
    ) s
    WHERE dv.dataset_version_id = p_version_id;

    INSERT INTO data_quality.data_audit (dataset_id, source_table, record_id, action, reason, new_value)
    VALUES (v.dataset_id, 'dataset.dataset_versions', p_version_id::text, 'CREATE',
            'build_version', jsonb_build_object('records', v_rows));

    RETURN v_rows;
END;
$$;

-- Đóng băng version: kiểm tra đủ quan sát hợp lệ, tính checksum
CREATE OR REPLACE FUNCTION dataset.freeze_version(p_version_id UUID)
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
    v_min   INTEGER;
    v_valid INTEGER;
    v_sum   TEXT;
BEGIN
    SELECT d.min_valid_observations, dv.valid_count INTO v_min, v_valid
    FROM dataset.dataset_versions dv JOIN dataset.datasets d USING (dataset_id)
    WHERE dv.dataset_version_id = p_version_id;

    IF COALESCE(v_valid, 0) < v_min THEN
        RAISE EXCEPTION 'Chưa đủ quan sát hợp lệ: % / % yêu cầu', COALESCE(v_valid, 0), v_min;
    END IF;

    SELECT md5(string_agg(record_id::text, ',' ORDER BY record_id)) INTO v_sum
    FROM dataset.dataset_records WHERE dataset_version_id = p_version_id;

    UPDATE dataset.dataset_versions
    SET status = 'FROZEN', frozen_at = now(), checksum = v_sum,
        labeled_count = (SELECT count(*) FROM dataset.dataset_records
                         WHERE dataset_version_id = p_version_id AND label_id IS NOT NULL)
    WHERE dataset_version_id = p_version_id;
    RETURN v_sum;
END;
$$;

-- ---------------------------------------------------------------------
-- Màn hình 09: mức sẵn sàng của dataset version + kiểm tra leakage
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW dataset.v_version_readiness AS
SELECT dv.dataset_version_id, d.dataset_code, dv.version_no, dv.status, dv.split_strategy,
       count(r.record_id)                                   AS records,
       count(r.record_id) FILTER (WHERE r.valid_flag)       AS valid_records,
       count(r.record_id) FILTER (WHERE r.label_id IS NOT NULL) AS labeled_records,
       count(r.record_id) FILTER (WHERE r.split = 'TRAIN')  AS train,
       count(r.record_id) FILTER (WHERE r.split = 'VAL')    AS val,
       count(r.record_id) FILTER (WHERE r.split = 'TEST')   AS test,
       d.min_valid_observations,
       count(r.record_id) FILTER (WHERE r.valid_flag) >= d.min_valid_observations AS meets_min_observations,
       (SELECT count(*) FROM (
            SELECT group_key FROM dataset.dataset_records x
            WHERE x.dataset_version_id = dv.dataset_version_id
            GROUP BY group_key HAVING count(DISTINCT split) > 1) z) AS leaking_groups
FROM dataset.dataset_versions dv
JOIN dataset.datasets d USING (dataset_id)
LEFT JOIN dataset.dataset_records r ON r.dataset_version_id = dv.dataset_version_id
GROUP BY dv.dataset_version_id, d.dataset_code, dv.version_no, dv.status, dv.split_strategy,
         d.min_valid_observations;

-- >>>>> 10_sqi.sql
-- =====================================================================
-- 10_sqi.sql : chỉ số sức khỏe đất (Soil Quality Index)
-- SQI = Σ (weight_i × score_i) / Σ weight_i  (thang 0–1), score_i chuẩn hóa tuyến tính
-- =====================================================================

CREATE TABLE sqi.sqi_definitions (
    definition_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version_code    VARCHAR(32)  NOT NULL UNIQUE,          -- vd: SQI-v1.0
    name            VARCHAR(255) NOT NULL,
    method          VARCHAR(32)  NOT NULL DEFAULT 'LINEAR_WEIGHTED'
                    CHECK (method IN ('LINEAR_WEIGHTED','PCA_MDS','NONLINEAR_WEIGHTED','EXPERT')),
    min_indicator_coverage_pct NUMERIC(5,2) NOT NULL DEFAULT 70,   -- tối thiểu % trọng số có dữ liệu
    status          VARCHAR(16)  NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','ACTIVE','RETIRED')),
    valid_from      DATE,
    approved_by     UUID         REFERENCES iam.users(user_id),
    description     TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE sqi.sqi_indicators (
    indicator_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_id   UUID         NOT NULL REFERENCES sqi.sqi_definitions(definition_id) ON DELETE CASCADE,
    parameter_code  VARCHAR(32)  NOT NULL REFERENCES ref.parameters(parameter_code),
    source          VARCHAR(8)   NOT NULL DEFAULT 'SENSOR' CHECK (source IN ('SENSOR','LAB')),
    scoring_function VARCHAR(16) NOT NULL
                    CHECK (scoring_function IN ('MORE_IS_BETTER','LESS_IS_BETTER','OPTIMUM')),
    lower_limit     NUMERIC      NOT NULL,                 -- score = 0 tại/ngoài giới hạn
    upper_limit     NUMERIC      NOT NULL,
    optimum_low     NUMERIC,                               -- OPTIMUM: score = 1 trong [low, high]
    optimum_high    NUMERIC,
    UNIQUE (definition_id, parameter_code),
    CHECK (upper_limit > lower_limit),
    CHECK (scoring_function <> 'OPTIMUM'
           OR (optimum_low IS NOT NULL AND optimum_high IS NOT NULL
               AND lower_limit <= optimum_low AND optimum_low <= optimum_high AND optimum_high <= upper_limit))
);

CREATE TABLE sqi.sqi_weights (
    weight_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_id   UUID         NOT NULL REFERENCES sqi.sqi_definitions(definition_id) ON DELETE CASCADE,
    indicator_id    UUID         NOT NULL REFERENCES sqi.sqi_indicators(indicator_id) ON DELETE CASCADE,
    weight          NUMERIC(6,4) NOT NULL CHECK (weight > 0 AND weight <= 1),
    weighting_method VARCHAR(16) NOT NULL DEFAULT 'EXPERT'
                    CHECK (weighting_method IN ('EQUAL','PCA','AHP','EXPERT')),
    UNIQUE (definition_id, indicator_id)
);

-- Ngưỡng phân loại sức khỏe đất; class_code trùng dataset.labels.label_code
CREATE TABLE sqi.sqi_classes (
    definition_id   UUID         NOT NULL REFERENCES sqi.sqi_definitions(definition_id) ON DELETE CASCADE,
    class_code      VARCHAR(32)  NOT NULL,
    min_value       NUMERIC(6,4) NOT NULL,                 -- [min, max)
    max_value       NUMERIC(6,4) NOT NULL,
    PRIMARY KEY (definition_id, class_code),
    CHECK (max_value > min_value)
);

CREATE TABLE sqi.sqi_scores (
    sqi_score_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_id   UUID         NOT NULL REFERENCES sqi.sqi_definitions(definition_id),
    dataset_version_id UUID      REFERENCES dataset.dataset_versions(dataset_version_id),
    plot_id         UUID         NOT NULL REFERENCES farm.plots(plot_id),
    treatment_id    UUID         REFERENCES experiment.treatments(treatment_id),
    period_start    TIMESTAMPTZ  NOT NULL,
    period_end      TIMESTAMPTZ  NOT NULL,
    sqi_value       NUMERIC(6,4) NOT NULL CHECK (sqi_value BETWEEN 0 AND 1),
    health_class    VARCHAR(32)  NOT NULL,
    coverage_pct    NUMERIC(5,2) NOT NULL,                 -- % trọng số có dữ liệu
    n_observations  INTEGER,
    computed_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (definition_id, plot_id, period_start),
    CHECK (period_end > period_start)
);

-- Điểm từng chỉ tiêu (màn hình 04: xem chi tiết từng chỉ tiêu, trọng số)
CREATE TABLE sqi.sqi_indicator_scores (
    sqi_score_id    UUID         NOT NULL REFERENCES sqi.sqi_scores(sqi_score_id) ON DELETE CASCADE,
    indicator_id    UUID         NOT NULL REFERENCES sqi.sqi_indicators(indicator_id),
    raw_value       NUMERIC,
    score           NUMERIC(6,4),
    weight          NUMERIC(6,4),
    weighted_score  NUMERIC(8,6),
    PRIMARY KEY (sqi_score_id, indicator_id)
);

CREATE INDEX ix_sqi_scores_plot_time ON sqi.sqi_scores(plot_id, period_start);
CREATE INDEX ix_sqi_scores_treatment ON sqi.sqi_scores(treatment_id, period_start);

-- ---------------------------------------------------------------------
-- Chuẩn hóa 1 chỉ tiêu về [0,1]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sqi.score_indicator(
    p_value NUMERIC, p_function VARCHAR,
    p_lower NUMERIC, p_upper NUMERIC, p_opt_low NUMERIC, p_opt_high NUMERIC
) RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_value IS NULL THEN NULL
        WHEN p_function = 'MORE_IS_BETTER' THEN
            LEAST(GREATEST((p_value - p_lower) / (p_upper - p_lower), 0), 1)
        WHEN p_function = 'LESS_IS_BETTER' THEN
            LEAST(GREATEST((p_upper - p_value) / (p_upper - p_lower), 0), 1)
        WHEN p_function = 'OPTIMUM' THEN
            CASE WHEN p_value BETWEEN p_opt_low AND p_opt_high THEN 1
                 WHEN p_value <= p_lower OR p_value >= p_upper THEN 0
                 WHEN p_value < p_opt_low THEN (p_value - p_lower) / NULLIF(p_opt_low - p_lower, 0)
                 ELSE (p_upper - p_value) / NULLIF(p_upper - p_opt_high, 0) END
    END;
$$;

-- ---------------------------------------------------------------------
-- Tính SQI theo ngày cho mọi ô trong 1 dataset version.
-- Đầu vào: dataset.dataset_records hợp lệ (sensor cột + lab_payload).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sqi.calculate_daily(p_definition_id UUID, p_dataset_version_id UUID)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_cov   NUMERIC;
    v_count INTEGER;
BEGIN
    SELECT min_indicator_coverage_pct INTO v_cov
    FROM sqi.sqi_definitions WHERE definition_id = p_definition_id;

    DELETE FROM sqi.sqi_scores
    WHERE definition_id = p_definition_id AND dataset_version_id = p_dataset_version_id;

    DROP TABLE IF EXISTS _sqi_ind;
    CREATE TEMP TABLE _sqi_ind ON COMMIT DROP AS
    WITH feat AS (
        SELECT r.plot_id, date_trunc('day', r.observed_at) AS day, r.treatment_id,
               kv.key AS parameter_code, kv.value::numeric AS value
        FROM dataset.dataset_records r
        CROSS JOIN LATERAL jsonb_each_text(
            jsonb_strip_nulls(jsonb_build_object(
                'PH', r.ph, 'EC', r.ec, 'MOISTURE', r.soil_moisture, 'SOIL_TEMP', r.soil_temperature,
                'N', r.n, 'P', r.p, 'K', r.k))
            || COALESCE(r.lab_payload, '{}'::jsonb)) kv
        WHERE r.dataset_version_id = p_dataset_version_id AND r.valid_flag
    ),
    daily AS (
        SELECT plot_id, day, parameter_code, avg(value) AS value, count(*) AS n,
               (array_agg(treatment_id))[1] AS treatment_id
        FROM feat GROUP BY plot_id, day, parameter_code
    )
    SELECT d.plot_id, d.day, d.treatment_id, d.n, i.indicator_id, d.value,
           sqi.score_indicator(d.value, i.scoring_function, i.lower_limit, i.upper_limit,
                               i.optimum_low, i.optimum_high) AS score,
           w.weight
    FROM daily d
    JOIN sqi.sqi_indicators i ON i.definition_id = p_definition_id AND i.parameter_code = d.parameter_code
    JOIN sqi.sqi_weights w    ON w.indicator_id = i.indicator_id;

    WITH agg AS (
        SELECT plot_id, day, max(treatment_id::text)::uuid AS treatment_id, max(n) AS n_obs,
               sum(weight * score) / NULLIF(sum(weight), 0) AS sqi_value,
               sum(weight) * 100 / (SELECT sum(weight) FROM sqi.sqi_weights WHERE definition_id = p_definition_id)
                   AS coverage
        FROM _sqi_ind GROUP BY plot_id, day
    ),
    ins AS (
        INSERT INTO sqi.sqi_scores (definition_id, dataset_version_id, plot_id, treatment_id,
                                    period_start, period_end, sqi_value, health_class, coverage_pct, n_observations)
        SELECT p_definition_id, p_dataset_version_id, a.plot_id, a.treatment_id,
               a.day, a.day + INTERVAL '1 day', round(a.sqi_value, 4),
               COALESCE(c.class_code, 'UNKNOWN'), round(a.coverage, 2), a.n_obs
        FROM agg a
        LEFT JOIN sqi.sqi_classes c ON c.definition_id = p_definition_id
             AND a.sqi_value >= c.min_value AND a.sqi_value < c.max_value
        WHERE a.coverage >= v_cov
        RETURNING sqi_score_id, plot_id, period_start
    )
    INSERT INTO sqi.sqi_indicator_scores (sqi_score_id, indicator_id, raw_value, score, weight, weighted_score)
    SELECT ins.sqi_score_id, t.indicator_id, round(t.value, 4), round(t.score, 4), t.weight,
           round(t.score * t.weight, 6)
    FROM ins JOIN _sqi_ind t ON t.plot_id = ins.plot_id AND t.day = ins.period_start;

    SELECT count(*) INTO v_count FROM sqi.sqi_scores
    WHERE definition_id = p_definition_id AND dataset_version_id = p_dataset_version_id;

    DROP TABLE IF EXISTS _sqi_ind;
    RETURN v_count;
END;
$$;

-- Gán nhãn sức khỏe đất cho dataset_records từ SQI ngày tương ứng
CREATE OR REPLACE FUNCTION sqi.assign_labels(p_definition_id UUID, p_dataset_version_id UUID)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_rows INTEGER;
BEGIN
    UPDATE dataset.dataset_records r
    SET label_id = l.label_id, label_source = 'SQI_RULE'
    FROM sqi.sqi_scores s
    JOIN dataset.labels l ON l.label_set = 'SOIL_HEALTH' AND l.label_code = s.health_class
    WHERE r.dataset_version_id = p_dataset_version_id
      AND s.definition_id = p_definition_id
      AND s.dataset_version_id = p_dataset_version_id
      AND s.plot_id = r.plot_id
      AND r.observed_at >= s.period_start AND r.observed_at < s.period_end
      AND r.valid_flag
      AND (r.label_source IS NULL OR r.label_source = 'SQI_RULE');   -- không ghi đè nhãn chuyên gia
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE dataset.dataset_versions
    SET labeled_count = (SELECT count(*) FROM dataset.dataset_records
                         WHERE dataset_version_id = p_dataset_version_id AND label_id IS NOT NULL)
    WHERE dataset_version_id = p_dataset_version_id;
    RETURN v_rows;
END;
$$;

-- Màn hình 04: so sánh SQI giữa các nghiệm thức
CREATE OR REPLACE VIEW sqi.v_treatment_comparison AS
SELECT d.version_code, t.treatment_code, t.name AS treatment_name, t.biochar_dose_kg_m2, t.control_flag,
       count(*)                       AS n_days,
       round(avg(s.sqi_value), 4)     AS mean_sqi,
       round(stddev_samp(s.sqi_value), 4) AS sd_sqi,
       round(min(s.sqi_value), 4)     AS min_sqi,
       round(max(s.sqi_value), 4)     AS max_sqi,
       mode() WITHIN GROUP (ORDER BY s.health_class) AS dominant_class
FROM sqi.sqi_scores s
JOIN sqi.sqi_definitions d ON d.definition_id = s.definition_id
JOIN experiment.treatments t ON t.treatment_id = s.treatment_id
GROUP BY d.version_code, t.treatment_code, t.name, t.biochar_dose_kg_m2, t.control_flag;

-- >>>>> 11_ml.sql
-- =====================================================================
-- 11_ml.sql : Embedded ML – model registry, phiên bản, metrics, suy luận tại Edge
-- Tiêu chí nghiệm thu: Accuracy ≥90%, Precision ≥90%, Recall ≥80%, F1 ≥85%,
-- thời gian suy luận ≤2 s/mẫu
-- =====================================================================

CREATE TABLE ml.models (
    model_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_code      VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    task_type       VARCHAR(32)  NOT NULL
                    CHECK (task_type IN ('ANOMALY_DETECTION','CLASSIFICATION','FORECASTING','REGRESSION')),
    target          VARCHAR(64)  NOT NULL,                 -- vd: SOIL_HEALTH_CLASS, MOISTURE_T+24H, SENSOR_ANOMALY
    algorithm       VARCHAR(64),                           -- RandomForest, 1D-CNN, LSTM, IsolationForest, ...
    owner_id        UUID         REFERENCES iam.users(user_id),
    description     TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE ml.model_versions (
    model_version_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_id        UUID         NOT NULL REFERENCES ml.models(model_id),
    version         VARCHAR(32)  NOT NULL,                 -- semver
    dataset_version_id UUID      REFERENCES dataset.dataset_versions(dataset_version_id),
    framework       VARCHAR(16)  NOT NULL CHECK (framework IN ('TFLITE','TFLM','ONNX','SKLEARN','EDGE_IMPULSE','OTHER')),
    quantization    VARCHAR(8)   CHECK (quantization IN ('FP32','FP16','INT8')),
    artifact_uri    TEXT         NOT NULL,
    artifact_sha256 CHAR(64)     NOT NULL,
    size_kb         NUMERIC(10,2),
    input_schema    JSONB,                                 -- danh sách feature, thứ tự, chuẩn hóa
    output_schema   JSONB,
    hyperparameters JSONB,
    target_hardware VARCHAR(64),
    min_firmware_version VARCHAR(32),
    status          VARCHAR(16)  NOT NULL DEFAULT 'TRAINED'
                    CHECK (status IN ('TRAINED','VALIDATING','APPROVED','DEPLOYED','RETIRED','REJECTED')),
    trained_at      TIMESTAMPTZ,
    approved_by     UUID         REFERENCES iam.users(user_id),
    approved_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (model_id, version)
);

CREATE TABLE ml.model_metrics (
    metric_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_version_id UUID        NOT NULL REFERENCES ml.model_versions(model_version_id) ON DELETE CASCADE,
    dataset_version_id UUID      REFERENCES dataset.dataset_versions(dataset_version_id),
    split           VARCHAR(8)   NOT NULL CHECK (split IN ('TRAIN','VAL','TEST','FIELD')),
    environment     VARCHAR(8)   NOT NULL DEFAULT 'OFFLINE' CHECK (environment IN ('OFFLINE','EDGE')),
    metric_name     VARCHAR(32)  NOT NULL
                    CHECK (metric_name IN ('ACCURACY','PRECISION','RECALL','F1','AUC','RMSE','MAE','MAPE','R2',
                                           'LATENCY_MS_AVG','LATENCY_MS_P95','RAM_KB','FLASH_KB')),
    metric_value    NUMERIC      NOT NULL,
    per_class       JSONB,                                 -- metric theo lớp / confusion matrix
    evaluated_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (model_version_id, split, environment, metric_name)
);

CREATE TABLE ml.inference_results (
    inference_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    model_version_id UUID        NOT NULL REFERENCES ml.model_versions(model_version_id),
    gateway_id      UUID         NOT NULL REFERENCES iot.gateways(gateway_id),
    node_id         UUID         REFERENCES iot.sensor_nodes(node_id),
    plot_id         UUID         REFERENCES farm.plots(plot_id),
    inferred_at     TIMESTAMPTZ  NOT NULL,
    task_type       VARCHAR(32)  NOT NULL
                    CHECK (task_type IN ('ANOMALY_DETECTION','CLASSIFICATION','FORECASTING','REGRESSION')),
    input_record_id UUID,                                  -- dataset.dataset_records.record_id (nếu có)
    input_reading_id BIGINT,                               -- iot.sensor_readings.reading_id (nếu suy luận trực tiếp)
    input_features  JSONB,
    prediction      JSONB        NOT NULL,                 -- {"class":"GOOD","proba":{...}} / {"moisture_t24":28.1}
    predicted_label VARCHAR(32),
    confidence      NUMERIC(5,4) CHECK (confidence BETWEEN 0 AND 1),
    anomaly_score   NUMERIC,
    is_anomaly      BOOLEAN,
    latency_ms      NUMERIC(10,2) CHECK (latency_ms >= 0),
    ground_truth_label VARCHAR(32),                        -- đánh giá ngoài thực địa
    received_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ix_inference_gateway_time ON ml.inference_results(gateway_id, inferred_at);
CREATE INDEX ix_inference_plot_time    ON ml.inference_results(plot_id, inferred_at);
CREATE INDEX ix_inference_model        ON ml.inference_results(model_version_id, inferred_at);
CREATE INDEX ix_model_versions_model   ON ml.model_versions(model_id);

ALTER TABLE iot.gateways
    ADD CONSTRAINT fk_gateways_current_model
    FOREIGN KEY (current_model_version_id) REFERENCES ml.model_versions(model_version_id);

-- ---------------------------------------------------------------------
-- Kiểm tra tiêu chí nghiệm thu của model version (split TEST, OFFLINE)
-- + độ trễ thực tế tại Edge từ inference_results
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW ml.v_model_acceptance AS
WITH m AS (
    SELECT model_version_id,
           max(metric_value) FILTER (WHERE metric_name = 'ACCURACY')  AS accuracy,
           max(metric_value) FILTER (WHERE metric_name = 'PRECISION') AS precision_,
           max(metric_value) FILTER (WHERE metric_name = 'RECALL')    AS recall,
           max(metric_value) FILTER (WHERE metric_name = 'F1')        AS f1
    FROM ml.model_metrics
    WHERE split = 'TEST' AND environment = 'OFFLINE'
    GROUP BY model_version_id
),
lat AS (
    SELECT model_version_id,
           count(*) AS n_inferences,
           avg(latency_ms) AS latency_ms_avg,
           percentile_cont(0.95) WITHIN GROUP (ORDER BY latency_ms) AS latency_ms_p95
    FROM ml.inference_results
    GROUP BY model_version_id
)
SELECT mo.model_code, mo.task_type, mv.version, mv.status, mv.model_version_id,
       m.accuracy, m.precision_ AS precision, m.recall, m.f1,
       lat.n_inferences, round(lat.latency_ms_avg, 2) AS latency_ms_avg,
       round(lat.latency_ms_p95::numeric, 2) AS latency_ms_p95,
       (m.accuracy  >= 0.90) AS accuracy_ok,
       (m.precision_ >= 0.90) AS precision_ok,
       (m.recall    >= 0.80) AS recall_ok,
       (m.f1        >= 0.85) AS f1_ok,
       (lat.latency_ms_p95 IS NULL OR lat.latency_ms_p95 <= 2000) AS latency_ok,
       COALESCE(m.accuracy >= 0.90 AND m.precision_ >= 0.90 AND m.recall >= 0.80 AND m.f1 >= 0.85
                AND (lat.latency_ms_p95 IS NULL OR lat.latency_ms_p95 <= 2000), false) AS passed
FROM ml.model_versions mv
JOIN ml.models mo USING (model_id)
LEFT JOIN m   USING (model_version_id)
LEFT JOIN lat USING (model_version_id);

-- Duyệt model: chỉ cho APPROVED khi đạt tiêu chí (áp dụng cho bài toán phân loại / anomaly)
CREATE OR REPLACE FUNCTION ml.approve_model_version(p_model_version_id UUID, p_user UUID)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_task   VARCHAR;
    v_passed BOOLEAN;
BEGIN
    SELECT task_type, passed INTO v_task, v_passed
    FROM ml.v_model_acceptance WHERE model_version_id = p_model_version_id;
    IF v_task IS NULL THEN
        RAISE EXCEPTION 'Model version % không tồn tại', p_model_version_id;
    END IF;
    IF v_task IN ('CLASSIFICATION','ANOMALY_DETECTION') AND NOT v_passed THEN
        RAISE EXCEPTION 'Model version % chưa đạt tiêu chí nghiệm thu (ACC≥0.90, P≥0.90, R≥0.80, F1≥0.85)',
            p_model_version_id;
    END IF;
    UPDATE ml.model_versions
    SET status = 'APPROVED', approved_by = p_user, approved_at = now()
    WHERE model_version_id = p_model_version_id;
END;
$$;

-- >>>>> 12_ota.sql
-- =====================================================================
-- 12_ota.sql : gói cập nhật mô hình / firmware và triển khai OTA
-- Vòng đời: PENDING → DOWNLOADING → VERIFY → ACTIVE | FAILED → ROLLBACK
-- Tiêu chí: OTA thành công ≥95%, thời gian cập nhật ≤10 phút
-- =====================================================================

CREATE TABLE ota.ota_packages (
    package_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    package_code    VARCHAR(64)  NOT NULL UNIQUE,
    package_type    VARCHAR(16)  NOT NULL CHECK (package_type IN ('MODEL','FIRMWARE','CONFIG')),
    model_version_id UUID        REFERENCES ml.model_versions(model_version_id),
    version         VARCHAR(32)  NOT NULL,
    artifact_uri    TEXT         NOT NULL,
    sha256          CHAR(64)     NOT NULL,
    signature       TEXT,                                  -- chữ ký số của gói
    size_bytes      BIGINT       NOT NULL CHECK (size_bytes > 0),
    compatible_hardware VARCHAR(64)[] NOT NULL DEFAULT '{}',
    min_firmware_version VARCHAR(32),
    release_notes   TEXT,
    status          VARCHAR(16)  NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','RELEASED','REVOKED')),
    created_by      UUID         REFERENCES iam.users(user_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (package_type <> 'MODEL' OR model_version_id IS NOT NULL)
);

CREATE TABLE ota.ota_deployments (
    deployment_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    package_id      UUID         NOT NULL REFERENCES ota.ota_packages(package_id),
    gateway_id      UUID         NOT NULL REFERENCES iot.gateways(gateway_id),
    node_id         UUID         REFERENCES iot.sensor_nodes(node_id),   -- NULL = cập nhật chính gateway
    previous_package_id UUID     REFERENCES ota.ota_packages(package_id), -- gói để rollback về
    attempt_no      SMALLINT     NOT NULL DEFAULT 1,
    status          VARCHAR(16)  NOT NULL DEFAULT 'PENDING'
                    CHECK (status IN ('PENDING','DOWNLOADING','VERIFY','ACTIVE','FAILED','ROLLBACK')),
    progress_pct    NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (progress_pct BETWEEN 0 AND 100),
    integrity_ok    BOOLEAN,                               -- checksum/chữ ký khớp
    compatibility_ok BOOLEAN,
    started_at      TIMESTAMPTZ,
    finished_at     TIMESTAMPTZ,
    duration_s      NUMERIC GENERATED ALWAYS AS (EXTRACT(EPOCH FROM finished_at - started_at)) STORED,
    error_message   TEXT,
    initiated_by    UUID         REFERENCES iam.users(user_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at),
    CHECK (status <> 'ACTIVE' OR integrity_ok IS TRUE)     -- không kích hoạt gói sai checksum
);

-- Lịch sử chuyển trạng thái (timeline cho màn hình 11)
CREATE TABLE ota.deployment_events (
    event_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    deployment_id   UUID         NOT NULL REFERENCES ota.ota_deployments(deployment_id) ON DELETE CASCADE,
    from_status     VARCHAR(16),
    to_status       VARCHAR(16)  NOT NULL,
    progress_pct    NUMERIC(5,2),
    message         TEXT,
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE ota.rollback_events (
    rollback_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    deployment_id   UUID         NOT NULL REFERENCES ota.ota_deployments(deployment_id),
    from_package_id UUID         NOT NULL REFERENCES ota.ota_packages(package_id),
    to_package_id   UUID         REFERENCES ota.ota_packages(package_id),
    reason          TEXT         NOT NULL,
    trigger_type    VARCHAR(8)   NOT NULL DEFAULT 'AUTO' CHECK (trigger_type IN ('AUTO','MANUAL')),
    triggered_by    UUID         REFERENCES iam.users(user_id),
    triggered_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    success         BOOLEAN
);

CREATE INDEX ix_ota_deploy_gateway ON ota.ota_deployments(gateway_id, created_at);
CREATE INDEX ix_ota_deploy_status  ON ota.ota_deployments(status);
CREATE INDEX ix_ota_events_deploy  ON ota.deployment_events(deployment_id, occurred_at);

-- ---------------------------------------------------------------------
-- Trigger chuyển trạng thái:
--  * ghi deployment_events
--  * kiểm tra luồng hợp lệ
--  * ACTIVE (gói MODEL)  -> cập nhật model đang chạy trên gateway, model_version = DEPLOYED
--  * ROLLBACK            -> trả gateway về model của previous_package, ghi rollback_events
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ota.on_deployment_status()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_pkg  ota.ota_packages%ROWTYPE;
    v_prev ota.ota_packages%ROWTYPE;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' AND NOT (
           (OLD.status = 'PENDING'     AND NEW.status IN ('DOWNLOADING','FAILED'))
        OR (OLD.status = 'DOWNLOADING' AND NEW.status IN ('VERIFY','FAILED'))
        OR (OLD.status = 'VERIFY'      AND NEW.status IN ('ACTIVE','FAILED'))
        OR (OLD.status = 'ACTIVE'      AND NEW.status = 'ROLLBACK')
        OR (OLD.status = 'FAILED'      AND NEW.status = 'ROLLBACK')) THEN
        RAISE EXCEPTION 'Chuyển trạng thái OTA không hợp lệ: % -> %', OLD.status, NEW.status;
    END IF;

    IF NEW.status = 'DOWNLOADING' AND NEW.started_at IS NULL THEN
        NEW.started_at := now();
    END IF;
    IF NEW.status IN ('ACTIVE','FAILED') AND NEW.finished_at IS NULL THEN
        NEW.finished_at := now();
    END IF;
    IF NEW.status = 'ACTIVE' THEN
        NEW.progress_pct := 100;
    END IF;

    SELECT * INTO v_pkg FROM ota.ota_packages WHERE package_id = NEW.package_id;

    IF NEW.status = 'ACTIVE' AND v_pkg.package_type = 'MODEL' AND NEW.node_id IS NULL THEN
        UPDATE iot.gateways SET current_model_version_id = v_pkg.model_version_id
        WHERE gateway_id = NEW.gateway_id;
        UPDATE ml.model_versions SET status = 'DEPLOYED'
        WHERE model_version_id = v_pkg.model_version_id;
    ELSIF NEW.status = 'ACTIVE' AND v_pkg.package_type = 'FIRMWARE' THEN
        IF NEW.node_id IS NULL THEN
            UPDATE iot.gateways SET firmware_version = v_pkg.version WHERE gateway_id = NEW.gateway_id;
        ELSE
            UPDATE iot.sensor_nodes SET firmware_version = v_pkg.version WHERE node_id = NEW.node_id;
        END IF;
    END IF;

    IF NEW.status = 'ROLLBACK' THEN
        SELECT * INTO v_prev FROM ota.ota_packages WHERE package_id = NEW.previous_package_id;
        IF v_pkg.package_type = 'MODEL' AND NEW.node_id IS NULL THEN
            UPDATE iot.gateways SET current_model_version_id = v_prev.model_version_id
            WHERE gateway_id = NEW.gateway_id;
        END IF;
        INSERT INTO ota.rollback_events (deployment_id, from_package_id, to_package_id, reason, trigger_type, success)
        VALUES (NEW.deployment_id, NEW.package_id, NEW.previous_package_id,
                COALESCE(NEW.error_message, 'Rollback'),
                CASE WHEN OLD.status = 'FAILED' THEN 'AUTO' ELSE 'MANUAL' END,
                true);
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION ota.log_deployment_event()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status OR NEW.progress_pct IS DISTINCT FROM OLD.progress_pct THEN
        INSERT INTO ota.deployment_events (deployment_id, from_status, to_status, progress_pct, message)
        VALUES (NEW.deployment_id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END,
                NEW.status, NEW.progress_pct, NEW.error_message);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_ota_status BEFORE INSERT OR UPDATE OF status ON ota.ota_deployments
    FOR EACH ROW EXECUTE FUNCTION ota.on_deployment_status();
CREATE TRIGGER trg_ota_events AFTER INSERT OR UPDATE ON ota.ota_deployments
    FOR EACH ROW EXECUTE FUNCTION ota.log_deployment_event();

-- KPI OTA
CREATE OR REPLACE VIEW ota.v_ota_kpi AS
SELECT p.package_type,
       count(*) FILTER (WHERE d.status IN ('ACTIVE','FAILED','ROLLBACK'))       AS finished,
       count(*) FILTER (WHERE d.status = 'ACTIVE')                               AS succeeded,
       round(count(*) FILTER (WHERE d.status = 'ACTIVE') * 100.0
             / NULLIF(count(*) FILTER (WHERE d.status IN ('ACTIVE','FAILED','ROLLBACK')), 0), 2) AS success_rate_pct,
       round(avg(d.duration_s) FILTER (WHERE d.status = 'ACTIVE') / 60, 2)       AS avg_duration_min,
       round(max(d.duration_s) FILTER (WHERE d.status = 'ACTIVE') / 60, 2)       AS max_duration_min,
       count(*) FILTER (WHERE d.status = 'ACTIVE' AND d.duration_s > 600)        AS over_10_min
FROM ota.ota_deployments d
JOIN ota.ota_packages p USING (package_id)
GROUP BY p.package_type;

-- >>>>> 13_alert.sql
-- =====================================================================
-- 13_alert.sql : luật cảnh báo, cảnh báo, khuyến nghị
-- (bảng recommendations đặt trong schema alert theo danh sách bảng của tài liệu)
-- =====================================================================

CREATE TABLE alert.alert_rules (
    rule_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rule_code       VARCHAR(32)  NOT NULL UNIQUE,
    name            VARCHAR(255) NOT NULL,
    source          VARCHAR(16)  NOT NULL CHECK (source IN ('SENSOR','SQI','ML','DEVICE','DATA_QUALITY')),
    parameter_code  VARCHAR(32)  REFERENCES ref.parameters(parameter_code),
    condition       VARCHAR(16)  NOT NULL
                    CHECK (condition IN ('LT','GT','OUTSIDE','CLASS_IN','ANOMALY','OFFLINE')),
    threshold_low   NUMERIC,
    threshold_high  NUMERIC,
    class_values    VARCHAR(32)[],                         -- CLASS_IN: {'POOR'}
    window_minutes  INTEGER      NOT NULL DEFAULT 60,      -- đánh giá trung bình trong cửa sổ
    cooldown_minutes INTEGER     NOT NULL DEFAULT 360,     -- không tạo cảnh báo trùng trong khoảng này
    severity        VARCHAR(8)   NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    plot_id         UUID         REFERENCES farm.plots(plot_id),   -- NULL = áp dụng mọi ô
    recommendation_category VARCHAR(32),
    recommendation_template TEXT,                          -- có thể dùng {value}, {plot}
    is_active       BOOLEAN      NOT NULL DEFAULT true,
    created_by      UUID         REFERENCES iam.users(user_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (condition <> 'LT'      OR threshold_low  IS NOT NULL),
    CHECK (condition <> 'GT'      OR threshold_high IS NOT NULL),
    CHECK (condition <> 'OUTSIDE' OR (threshold_low IS NOT NULL AND threshold_high IS NOT NULL)),
    CHECK (condition <> 'CLASS_IN' OR class_values IS NOT NULL)
);

CREATE TABLE alert.alerts (
    alert_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    plot_id         UUID         REFERENCES farm.plots(plot_id),
    node_id         UUID         REFERENCES iot.sensor_nodes(node_id),
    rule_id         UUID         REFERENCES alert.alert_rules(rule_id),
    severity        VARCHAR(8)   NOT NULL CHECK (severity IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    source          VARCHAR(16)  NOT NULL CHECK (source IN ('SENSOR','SQI','ML','DEVICE','DATA_QUALITY')),
    parameter_code  VARCHAR(32),
    triggered_value NUMERIC,
    message         TEXT         NOT NULL,
    evidence        JSONB,                                 -- bằng chứng SQI/AI: điểm, xác suất, chuỗi giá trị
    sqi_score_id    UUID         REFERENCES sqi.sqi_scores(sqi_score_id),
    inference_id    UUID         REFERENCES ml.inference_results(inference_id),
    status          VARCHAR(8)   NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ACK','RESOLVED')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    acknowledged_by UUID         REFERENCES iam.users(user_id),
    acknowledged_at TIMESTAMPTZ,
    resolved_by     UUID         REFERENCES iam.users(user_id),
    resolved_at     TIMESTAMPTZ,
    resolution_note TEXT,
    CHECK (status <> 'RESOLVED' OR resolved_at IS NOT NULL)
);

CREATE TABLE alert.recommendations (
    recommendation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    alert_id        UUID         REFERENCES alert.alerts(alert_id) ON DELETE SET NULL,
    plot_id         UUID         REFERENCES farm.plots(plot_id),
    category        VARCHAR(32)  NOT NULL
                    CHECK (category IN ('IRRIGATION','FERTILIZATION','BIOCHAR_DOSE','LIMING','DRAINAGE',
                                        'DEVICE_MAINTENANCE','RECALIBRATION','OTHER')),
    action_text     TEXT         NOT NULL,
    rationale       TEXT,
    source          VARCHAR(8)   NOT NULL DEFAULT 'RULE' CHECK (source IN ('RULE','ML','EXPERT')),
    priority        SMALLINT     NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    status          VARCHAR(16)  NOT NULL DEFAULT 'PROPOSED'
                    CHECK (status IN ('PROPOSED','ACCEPTED','REJECTED','DONE')),
    decided_by      UUID         REFERENCES iam.users(user_id),
    decided_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX ix_alerts_plot_time ON alert.alerts(plot_id, created_at);
CREATE INDEX ix_alerts_status    ON alert.alerts(status, severity);
CREATE INDEX ix_reco_alert       ON alert.recommendations(alert_id);

-- ---------------------------------------------------------------------
-- Đánh giá luật cảnh báo tại thời điểm p_at:
--   SENSOR: trung bình dữ liệu hợp lệ trong window_minutes
--   SQI   : điểm SQI mới nhất của ô
--   ML    : inference bất thường trong cửa sổ
--   DEVICE: node không gửi dữ liệu quá window_minutes
-- Tạo alert + recommendation; bỏ qua nếu đã có alert cùng luật/ô trong cooldown.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alert.evaluate_rules(p_at TIMESTAMPTZ DEFAULT now())
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    r       RECORD;
    c       RECORD;
    v_col   TEXT;
    v_alert UUID;
    v_count INTEGER := 0;
BEGIN
    FOR r IN SELECT * FROM alert.alert_rules WHERE is_active LOOP
        FOR c IN EXECUTE
            CASE r.source
            WHEN 'SENSOR' THEN format($q$
                SELECT sr.plot_id, (array_agg(sr.node_id))[1] AS node_id,
                       avg(%I) AS value, NULL::uuid AS sqi_score_id, NULL::uuid AS inference_id,
                       NULL::varchar AS class_value,
                       jsonb_build_object('window_min', $2, 'n', count(*), 'min', min(%I), 'max', max(%I)) AS evidence
                FROM iot.sensor_readings sr
                WHERE sr.measured_at > $1 - make_interval(mins => $2) AND sr.measured_at <= $1
                  AND sr.quality_status IN ('VALID','CORRECTED')
                  AND ($3::uuid IS NULL OR sr.plot_id = $3)
                GROUP BY sr.plot_id $q$,
                iot.reading_column(r.parameter_code), iot.reading_column(r.parameter_code),
                iot.reading_column(r.parameter_code))
            WHEN 'SQI' THEN $q$
                SELECT DISTINCT ON (s.plot_id) s.plot_id, NULL::uuid AS node_id, s.sqi_value AS value,
                       s.sqi_score_id, NULL::uuid AS inference_id, s.health_class::varchar AS class_value,
                       jsonb_build_object('sqi', s.sqi_value, 'class', s.health_class,
                                          'period_start', s.period_start, 'coverage_pct', s.coverage_pct) AS evidence
                FROM sqi.sqi_scores s
                WHERE s.period_start <= $1 AND s.period_start > $1 - make_interval(mins => GREATEST($2, 2880))
                  AND ($3::uuid IS NULL OR s.plot_id = $3)
                ORDER BY s.plot_id, s.period_start DESC $q$
            WHEN 'ML' THEN $q$
                SELECT DISTINCT ON (i.plot_id) i.plot_id, i.node_id, i.anomaly_score AS value,
                       NULL::uuid AS sqi_score_id, i.inference_id, i.predicted_label AS class_value,
                       jsonb_build_object('prediction', i.prediction, 'confidence', i.confidence,
                                          'anomaly_score', i.anomaly_score) AS evidence
                FROM ml.inference_results i
                WHERE i.inferred_at > $1 - make_interval(mins => $2) AND i.inferred_at <= $1
                  AND i.plot_id IS NOT NULL AND ($3::uuid IS NULL OR i.plot_id = $3)
                ORDER BY i.plot_id, i.is_anomaly DESC NULLS LAST, i.anomaly_score DESC NULLS LAST $q$
            WHEN 'DEVICE' THEN $q$
                SELECT n.plot_id, n.node_id,
                       EXTRACT(EPOCH FROM $1 - n.last_seen_at) / 60 AS value,
                       NULL::uuid AS sqi_score_id, NULL::uuid AS inference_id, NULL::varchar AS class_value,
                       jsonb_build_object('last_seen_at', n.last_seen_at, 'node_code', n.node_code) AS evidence
                FROM iot.sensor_nodes n
                WHERE n.status <> 'RETIRED'
                  AND (n.last_seen_at IS NULL OR n.last_seen_at < $1 - make_interval(mins => $2))
                  AND ($3::uuid IS NULL OR n.plot_id = $3) $q$
            ELSE 'SELECT NULL::uuid plot_id, NULL::uuid node_id, NULL::numeric value, NULL::uuid sqi_score_id,
                         NULL::uuid inference_id, NULL::varchar class_value, NULL::jsonb evidence
                  WHERE false AND $1 IS NULL AND $2 IS NULL AND $3 IS NULL'
            END
        USING p_at, r.window_minutes, r.plot_id
        LOOP
            CONTINUE WHEN NOT (
                   (r.condition = 'LT'       AND c.value < r.threshold_low)
                OR (r.condition = 'GT'       AND c.value > r.threshold_high)
                OR (r.condition = 'OUTSIDE'  AND (c.value < r.threshold_low OR c.value > r.threshold_high))
                OR (r.condition = 'CLASS_IN' AND c.class_value = ANY(r.class_values))
                OR (r.condition = 'ANOMALY'  AND (c.evidence->>'anomaly_score')::numeric >= COALESCE(r.threshold_high, 0.5))
                OR (r.condition = 'OFFLINE'));
            CONTINUE WHEN c.value IS NULL AND r.condition NOT IN ('CLASS_IN','OFFLINE');

            -- cooldown
            CONTINUE WHEN EXISTS (
                SELECT 1 FROM alert.alerts a
                WHERE a.rule_id = r.rule_id AND a.plot_id IS NOT DISTINCT FROM c.plot_id
                  AND a.status <> 'RESOLVED'
                  AND a.created_at > p_at - make_interval(mins => r.cooldown_minutes));

            v_alert := NULL;
            INSERT INTO alert.alerts (plot_id, node_id, rule_id, severity, source, parameter_code,
                                      triggered_value, message, evidence, sqi_score_id, inference_id, created_at)
            SELECT c.plot_id, c.node_id, r.rule_id, r.severity, r.source, r.parameter_code,
                   round(c.value, 4),
                   format('%s – ô %s: %s', r.name, p.plot_code, COALESCE(round(c.value, 2)::text, c.class_value, '')),
                   c.evidence, c.sqi_score_id, c.inference_id, p_at
            FROM farm.plots p WHERE p.plot_id = c.plot_id
            RETURNING alert_id INTO v_alert;

            IF v_alert IS NOT NULL AND r.recommendation_template IS NOT NULL THEN
                INSERT INTO alert.recommendations (alert_id, plot_id, category, action_text, rationale, priority)
                VALUES (v_alert, c.plot_id, COALESCE(r.recommendation_category, 'OTHER'),
                        replace(r.recommendation_template, '{value}', COALESCE(round(c.value, 2)::text, '')),
                        format('Luật %s (%s)', r.rule_code, r.condition),
                        CASE r.severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END);
            END IF;
            v_count := v_count + 1;
        END LOOP;
    END LOOP;
    RETURN v_count;
END;
$$;

-- >>>>> 14_reporting.sql
-- =====================================================================
-- 14_reporting.sql : KPI, báo cáo, kết quả kinh tế, view dashboard
-- =====================================================================

CREATE TABLE reporting.kpis (
    kpi_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kpi_code        VARCHAR(48)  NOT NULL UNIQUE,
    name_vi         VARCHAR(255) NOT NULL,
    domain          VARCHAR(32)  NOT NULL,                 -- iot, data_quality, dataset, ml, ota, ...
    unit            VARCHAR(16)  NOT NULL,
    comparator      VARCHAR(4)   NOT NULL CHECK (comparator IN ('GTE','LTE')),
    target_value    NUMERIC      NOT NULL,
    is_acceptance_criterion BOOLEAN NOT NULL DEFAULT true, -- tiêu chí nghiệm thu theo hồ sơ
    description     TEXT
);

CREATE TABLE reporting.kpi_measurements (
    measurement_id  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kpi_id          UUID         NOT NULL REFERENCES reporting.kpis(kpi_id),
    period_start    TIMESTAMPTZ  NOT NULL,
    period_end      TIMESTAMPTZ  NOT NULL,
    scope_type      VARCHAR(16)  NOT NULL DEFAULT 'SYSTEM' CHECK (scope_type IN ('SYSTEM','SITE','PLOT','NODE','MODEL')),
    scope_id        UUID,
    measured_value  NUMERIC,
    passed          BOOLEAN,
    measured_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE reporting.reports (
    report_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_type     VARCHAR(16)  NOT NULL
                    CHECK (report_type IN ('TECHNICAL','ECONOMIC','ENVIRONMENTAL','DATA_QUALITY','ML','OTA','SUMMARY')),
    title           VARCHAR(255) NOT NULL,
    experiment_id   UUID         REFERENCES experiment.experiments(experiment_id),
    crop_season_id  UUID         REFERENCES farm.crop_seasons(crop_season_id),
    period_start    DATE,
    period_end      DATE,
    parameters      JSONB,                                 -- bộ lọc dùng khi sinh báo cáo
    file_format     VARCHAR(8)   CHECK (file_format IN ('PDF','XLSX','CSV','DOCX')),
    file_uri        TEXT,
    status          VARCHAR(16)  NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','GENERATING','READY','FAILED')),
    generated_by    UUID         REFERENCES iam.users(user_id),
    generated_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Hiệu quả kinh tế theo nghiệm thức / mùa vụ
CREATE TABLE reporting.economic_results (
    economic_result_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id   UUID         NOT NULL REFERENCES experiment.experiments(experiment_id),
    treatment_id    UUID         NOT NULL REFERENCES experiment.treatments(treatment_id),
    crop_season_id  UUID         REFERENCES farm.crop_seasons(crop_season_id),
    plot_id         UUID         REFERENCES farm.plots(plot_id),
    yield_kg_m2     NUMERIC(10,3) NOT NULL CHECK (yield_kg_m2 >= 0),
    yield_t_ha      NUMERIC(10,3) GENERATED ALWAYS AS (yield_kg_m2 * 10) STORED,
    price_vnd_kg    NUMERIC(14,2) NOT NULL DEFAULT 0,
    cost_biochar_vnd_ha    NUMERIC(16,2) NOT NULL DEFAULT 0,
    cost_fertilizer_vnd_ha NUMERIC(16,2) NOT NULL DEFAULT 0,
    cost_labor_vnd_ha      NUMERIC(16,2) NOT NULL DEFAULT 0,
    cost_other_vnd_ha      NUMERIC(16,2) NOT NULL DEFAULT 0,
    revenue_vnd_ha  NUMERIC(18,2) GENERATED ALWAYS AS (yield_kg_m2 * 10000 * price_vnd_kg) STORED,
    total_cost_vnd_ha NUMERIC(18,2) GENERATED ALWAYS AS
                    (cost_biochar_vnd_ha + cost_fertilizer_vnd_ha + cost_labor_vnd_ha + cost_other_vnd_ha) STORED,
    profit_vnd_ha   NUMERIC(18,2) GENERATED ALWAYS AS
                    (yield_kg_m2 * 10000 * price_vnd_kg
                     - (cost_biochar_vnd_ha + cost_fertilizer_vnd_ha + cost_labor_vnd_ha + cost_other_vnd_ha)) STORED,
    bcr             NUMERIC(8,3) GENERATED ALWAYS AS
                    (CASE WHEN cost_biochar_vnd_ha + cost_fertilizer_vnd_ha + cost_labor_vnd_ha + cost_other_vnd_ha > 0
                          THEN yield_kg_m2 * 10000 * price_vnd_kg
                               / (cost_biochar_vnd_ha + cost_fertilizer_vnd_ha + cost_labor_vnd_ha + cost_other_vnd_ha)
                     END) STORED,
    carbon_sequestered_kg_ha NUMERIC(12,2),                -- chỉ tiêu môi trường
    notes           TEXT
);

CREATE INDEX ix_kpi_meas_kpi_time ON reporting.kpi_measurements(kpi_id, period_start);
CREATE INDEX ix_econ_treatment    ON reporting.economic_results(treatment_id);

-- ---------------------------------------------------------------------
-- KPI thu thập dữ liệu theo node / ngày
--   expected       = số lần đo kỳ vọng theo chu kỳ của node
--   success_rate   = bản tin nhận được / kỳ vọng           (≥ 90%)
--   timestamp_rate = bản tin timestamp hợp lệ / nhận được  (≥ 90%)
--   error_dup_rate = (INVALID + trùng) / (nhận + trùng)     (≤ 5%)
--   missing_rate   = (kỳ vọng − hợp lệ) / kỳ vọng           (≤ 5% sau xử lý)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_data_collection_daily AS
WITH rd AS (
    SELECT node_id, date_trunc('day', measured_at) AS day,
           count(*) AS received,
           count(*) FILTER (WHERE timestamp_valid) AS ts_valid,
           count(*) FILTER (WHERE quality_status IN ('VALID','CORRECTED')) AS valid,
           count(*) FILTER (WHERE quality_status = 'INVALID') AS invalid
    FROM iot.sensor_readings
    GROUP BY 1, 2
),
dup AS (
    SELECT s.node_id, date_trunc('day', i.observed_at) AS day, count(*) AS duplicates
    FROM data_quality.data_issues i
    JOIN iot.sensors s ON s.sensor_id = i.sensor_id
    WHERE i.issue_type = 'DUPLICATE'
    GROUP BY 1, 2
)
SELECT n.node_code, rd.node_id, rd.day,
       86400 / n.sampling_interval_s AS expected,
       rd.received, rd.ts_valid, rd.valid, rd.invalid, COALESCE(dup.duplicates, 0) AS duplicates,
       round(LEAST(rd.received * 100.0 / (86400 / n.sampling_interval_s), 100), 2) AS success_rate_pct,
       round(rd.ts_valid * 100.0 / NULLIF(rd.received, 0), 2) AS timestamp_valid_pct,
       round((rd.invalid + COALESCE(dup.duplicates, 0)) * 100.0
             / NULLIF(rd.received + COALESCE(dup.duplicates, 0), 0), 2) AS error_duplicate_pct,
       round(GREATEST(1 - rd.valid * 1.0 / (86400 / n.sampling_interval_s), 0) * 100, 2) AS missing_after_qc_pct
FROM rd
JOIN iot.sensor_nodes n ON n.node_id = rd.node_id
LEFT JOIN dup ON dup.node_id = rd.node_id AND dup.day = rd.day;

-- ---------------------------------------------------------------------
-- Bảng tổng hợp tiêu chí nghiệm thu (toàn hệ thống)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_acceptance_summary AS
WITH dc AS (
    SELECT sum(expected) expected, sum(received) received, sum(ts_valid) ts_valid,
           sum(valid) valid, sum(invalid) invalid, sum(duplicates) duplicates
    FROM reporting.v_data_collection_daily
),
ds AS (
    SELECT max(valid_records) AS best_valid FROM dataset.v_version_readiness
),
ml AS (   -- model phân loại/anomaly tốt nhất đang APPROVED/DEPLOYED, nếu không có thì model tốt nhất
    SELECT * FROM ml.v_model_acceptance
    WHERE task_type IN ('CLASSIFICATION','ANOMALY_DETECTION')
    ORDER BY (status IN ('APPROVED','DEPLOYED')) DESC, f1 DESC NULLS LAST LIMIT 1
),
ota AS (
    SELECT sum(succeeded) * 100.0 / NULLIF(sum(finished), 0) AS success_rate,
           max(max_duration_min) AS max_min
    FROM ota.v_ota_kpi
),
v(kpi_code, value) AS (
    SELECT 'DATA_COLLECTION_SUCCESS_PCT', (SELECT round(LEAST(received * 100.0 / NULLIF(expected, 0), 100), 2) FROM dc)
    UNION ALL SELECT 'TIMESTAMP_VALID_PCT',   (SELECT round(ts_valid * 100.0 / NULLIF(received, 0), 2) FROM dc)
    UNION ALL SELECT 'ERROR_DUPLICATE_PCT',   (SELECT round((invalid + duplicates) * 100.0 / NULLIF(received + duplicates, 0), 2) FROM dc)
    UNION ALL SELECT 'MISSING_AFTER_QC_PCT',  (SELECT round(GREATEST(1 - valid * 1.0 / NULLIF(expected, 0), 0) * 100, 2) FROM dc)
    UNION ALL SELECT 'VALID_OBSERVATIONS',    (SELECT best_valid FROM ds)
    UNION ALL SELECT 'ML_ACCURACY_PCT',       (SELECT accuracy * 100 FROM ml)
    UNION ALL SELECT 'ML_PRECISION_PCT',      (SELECT precision * 100 FROM ml)
    UNION ALL SELECT 'ML_RECALL_PCT',         (SELECT recall * 100 FROM ml)
    UNION ALL SELECT 'ML_F1_PCT',             (SELECT f1 * 100 FROM ml)
    UNION ALL SELECT 'ML_INFERENCE_MS',       (SELECT latency_ms_p95 FROM ml)
    UNION ALL SELECT 'OTA_SUCCESS_PCT',       (SELECT round(success_rate, 2) FROM ota)
    UNION ALL SELECT 'OTA_UPDATE_MINUTES',    (SELECT max_min FROM ota)
)
SELECT k.kpi_code, k.name_vi, k.unit, k.comparator, k.target_value, v.value AS current_value,
       CASE WHEN v.value IS NULL THEN NULL
            WHEN k.comparator = 'GTE' THEN v.value >= k.target_value
            ELSE v.value <= k.target_value END AS passed
FROM reporting.kpis k
LEFT JOIN v ON v.kpi_code = k.kpi_code
WHERE k.is_acceptance_criterion
ORDER BY k.domain, k.kpi_code;

-- Lưu snapshot KPI vào kpi_measurements
CREATE OR REPLACE FUNCTION reporting.snapshot_acceptance(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v_rows INTEGER;
BEGIN
    INSERT INTO reporting.kpi_measurements (kpi_id, period_start, period_end, measured_value, passed)
    SELECT k.kpi_id, p_from, p_to, s.current_value, s.passed
    FROM reporting.v_acceptance_summary s
    JOIN reporting.kpis k USING (kpi_code);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

-- ---------------------------------------------------------------------
-- Màn hình 01 – Dashboard tổng quan: mỗi ô một dòng
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.v_dashboard_plots AS
SELECT p.plot_id, p.plot_code, p.soil_type, s.site_code,
       t.treatment_code, t.biochar_dose_kg_m2,
       n.node_code, n.status AS node_status, n.last_seen_at, n.battery_v,
       g.gateway_code, g.status AS gateway_status,
       lr.measured_at AS last_reading_at, lr.ph, lr.ec, lr.soil_moisture, lr.n, lr.p, lr.k,
       sq.sqi_value, sq.health_class, sq.period_start AS sqi_date,
       (SELECT count(*) FROM alert.alerts a WHERE a.plot_id = p.plot_id AND a.status <> 'RESOLVED') AS open_alerts,
       mv.version AS gateway_model_version
FROM farm.plots p
JOIN farm.sites s ON s.site_id = p.site_id
LEFT JOIN LATERAL (
    SELECT ta.treatment_id FROM experiment.treatment_applications ta
    WHERE ta.plot_id = p.plot_id AND ta.effective_to IS NULL
    ORDER BY ta.effective_from DESC LIMIT 1) cur ON true
LEFT JOIN experiment.treatments t ON t.treatment_id = cur.treatment_id
LEFT JOIN iot.sensor_nodes n ON n.plot_id = p.plot_id AND n.status <> 'RETIRED'
LEFT JOIN iot.gateways g ON g.gateway_id = n.gateway_id
LEFT JOIN ml.model_versions mv ON mv.model_version_id = g.current_model_version_id
LEFT JOIN LATERAL (
    SELECT * FROM iot.sensor_readings r
    WHERE r.plot_id = p.plot_id AND r.quality_status IN ('VALID','CORRECTED')
    ORDER BY r.measured_at DESC LIMIT 1) lr ON true
LEFT JOIN LATERAL (
    SELECT * FROM sqi.sqi_scores q WHERE q.plot_id = p.plot_id
    ORDER BY q.period_start DESC LIMIT 1) sq ON true;

-- >>>>> 15_audit.sql
-- =====================================================================
-- 15_audit.sql : audit log hệ thống, nhật ký truy cập, trigger ghi thay đổi
-- Ứng dụng đặt người thực hiện bằng: SET LOCAL app.user_id = '<uuid>';
-- =====================================================================

CREATE TABLE audit.audit_logs (
    audit_log_id    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actor_id        UUID,
    actor_type      VARCHAR(16)  NOT NULL DEFAULT 'USER' CHECK (actor_type IN ('USER','SYSTEM','GATEWAY')),
    db_user         TEXT         NOT NULL DEFAULT current_user,
    schema_name     TEXT         NOT NULL,
    table_name      TEXT         NOT NULL,
    operation       VARCHAR(8)   NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    record_pk       JSONB,
    old_data        JSONB,
    new_data        JSONB,
    changed_fields  TEXT[],
    application     TEXT         DEFAULT current_setting('application_name', true),
    client_ip       INET
);

CREATE TABLE audit.access_logs (
    access_log_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    user_id         UUID         REFERENCES iam.users(user_id),
    api_key_id      UUID         REFERENCES iam.api_keys(api_key_id),
    action          VARCHAR(16)  NOT NULL
                    CHECK (action IN ('LOGIN','LOGOUT','LOGIN_FAILED','API_CALL','VIEW','EXPORT','DOWNLOAD')),
    resource        TEXT,
    http_method     VARCHAR(8),
    status_code     SMALLINT,
    ip_address      INET,
    user_agent      TEXT
);

CREATE INDEX ix_audit_logs_table_time ON audit.audit_logs(schema_name, table_name, occurred_at);
CREATE INDEX ix_audit_logs_actor      ON audit.audit_logs(actor_id, occurred_at);
CREATE INDEX ix_access_logs_user      ON audit.access_logs(user_id, occurred_at);

-- ---------------------------------------------------------------------
-- Trigger audit chung. TG_ARGV[0] = tên cột khóa chính.
-- Không ghi các cột nhạy cảm (password_hash, key_hash).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.log_change()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_old JSONB := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) - 'password_hash' - 'key_hash' END;
    v_new JSONB := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) - 'password_hash' - 'key_hash' END;
    v_pk  TEXT  := TG_ARGV[0];
    v_changed TEXT[];
    v_actor TEXT := NULLIF(current_setting('app.user_id', true), '');
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(n.key ORDER BY n.key) INTO v_changed
        FROM jsonb_each(v_new) n
        WHERE n.value IS DISTINCT FROM v_old -> n.key
          AND n.key NOT IN ('updated_at','last_seen_at','battery_v');   -- trường heartbeat, không audit
        IF v_changed IS NULL THEN RETURN NULL; END IF;     -- không có thay đổi đáng kể
    END IF;

    INSERT INTO audit.audit_logs (actor_id, actor_type, schema_name, table_name, operation,
                                  record_pk, old_data, new_data, changed_fields)
    VALUES (v_actor::uuid,
            CASE WHEN v_actor IS NULL THEN 'SYSTEM' ELSE 'USER' END,
            TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP,
            jsonb_build_object(v_pk, COALESCE(v_new, v_old) -> v_pk),
            v_old, v_new, v_changed);
    RETURN NULL;
END;
$$;

-- Gắn audit cho các bảng quan trọng ("All critical changes → audit")
DO $$
DECLARE
    t RECORD;
BEGIN
    FOR t IN SELECT * FROM (VALUES
        ('iam.users',                         'user_id'),
        ('iam.user_roles',                    'user_id'),
        ('iam.role_permissions',              'role_id'),
        ('iam.api_keys',                      'api_key_id'),
        ('farm.plots',                        'plot_id'),
        ('experiment.experiments',            'experiment_id'),
        ('experiment.treatments',             'treatment_id'),
        ('experiment.treatment_applications', 'application_id'),
        ('biochar.biochar_batches',           'biochar_batch_id'),
        ('iot.gateways',                      'gateway_id'),
        ('iot.sensor_nodes',                  'node_id'),
        ('iot.sensor_configs',                'config_id'),
        ('calibration.calibration_results',   'calibration_result_id'),
        ('laboratory.lab_results',            'lab_result_id'),
        ('data_quality.quality_rules',        'rule_id'),
        ('dataset.dataset_versions',          'dataset_version_id'),
        ('sqi.sqi_definitions',               'definition_id'),
        ('sqi.sqi_indicators',                'indicator_id'),
        ('sqi.sqi_weights',                   'weight_id'),
        ('ml.model_versions',                 'model_version_id'),
        ('ota.ota_packages',                  'package_id'),
        ('ota.ota_deployments',               'deployment_id'),
        ('alert.alert_rules',                 'rule_id'),
        ('alert.alerts',                      'alert_id'),
        ('alert.recommendations',             'recommendation_id'),
        ('reporting.kpis',                    'kpi_id')
    ) AS x(tbl, pk) LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %s
             FOR EACH ROW EXECUTE FUNCTION audit.log_change(%L)', t.tbl, t.pk);
    END LOOP;
END;
$$;

-- Sửa tay dữ liệu cảm biến (CORRECTED) -> lineage vào data_quality.data_audit
CREATE OR REPLACE FUNCTION audit.log_reading_correction()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.quality_status = 'CORRECTED' AND OLD.quality_status IS DISTINCT FROM 'CORRECTED' THEN
        INSERT INTO data_quality.data_audit (source_table, record_id, action, reason, old_value, new_value,
                                             actor_id, actor_type)
        VALUES ('iot.sensor_readings', NEW.reading_id::text, 'CLEAN',
                COALESCE(NULLIF(current_setting('app.change_reason', true), ''), 'Manual correction'),
                jsonb_build_object('ph', OLD.ph, 'ec', OLD.ec, 'soil_moisture', OLD.soil_moisture,
                                   'n', OLD.n, 'p', OLD.p, 'k', OLD.k, 'quality_status', OLD.quality_status),
                jsonb_build_object('ph', NEW.ph, 'ec', NEW.ec, 'soil_moisture', NEW.soil_moisture,
                                   'n', NEW.n, 'p', NEW.p, 'k', NEW.k, 'quality_status', NEW.quality_status),
                NULLIF(current_setting('app.user_id', true), '')::uuid,
                CASE WHEN NULLIF(current_setting('app.user_id', true), '') IS NULL THEN 'SYSTEM' ELSE 'USER' END);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_reading_correction AFTER UPDATE OF quality_status ON iot.sensor_readings
    FOR EACH ROW EXECUTE FUNCTION audit.log_reading_correction();

-- >>>>> 16_reference_data.sql
-- =====================================================================
-- 16_reference_data.sql : dữ liệu danh mục bắt buộc
-- (vai trò, quyền, KPI nghiệm thu, luật QC, nhãn, SQI v1.0, luật cảnh báo)
-- =====================================================================

-- ---------- IAM ----------
INSERT INTO iam.roles (role_code, name, description) VALUES
    ('ADMIN',         'Quản trị hệ thống',     'Toàn quyền'),
    ('RESEARCHER',    'Nghiên cứu viên',       'Quản lý thí nghiệm, dataset, SQI, model'),
    ('LAB_TECH',      'Kỹ thuật viên PTN',     'Nhập/duyệt kết quả phòng thí nghiệm'),
    ('FIELD_TECH',    'Kỹ thuật viên hiện trường', 'Thiết bị, hiệu chuẩn, lấy mẫu'),
    ('DATA_ENGINEER', 'Kỹ sư dữ liệu / ML',    'QC dữ liệu, dataset, model, OTA'),
    ('VIEWER',        'Người xem',             'Chỉ đọc dashboard và báo cáo');

INSERT INTO iam.permissions (permission_code, domain, action)
SELECT d || '.' || lower(a), d, a
FROM unnest(ARRAY['farm','experiment','biochar','iot','calibration','laboratory','data_quality',
                  'dataset','sqi','ml','ota','alert','reporting','audit','iam']) d
CROSS JOIN unnest(ARRAY['READ','WRITE']) a
UNION ALL SELECT 'laboratory.approve', 'laboratory', 'APPROVE'
UNION ALL SELECT 'ml.approve',         'ml',         'APPROVE'
UNION ALL SELECT 'ota.deploy',         'ota',        'DEPLOY'
UNION ALL SELECT 'iam.admin',          'iam',        'ADMIN';

INSERT INTO iam.role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM iam.roles r JOIN iam.permissions p ON
     r.role_code = 'ADMIN'
  OR (r.role_code = 'VIEWER'        AND p.action = 'READ' AND p.domain NOT IN ('iam','audit'))
  OR (r.role_code = 'RESEARCHER'    AND (p.action = 'READ' OR p.domain IN ('experiment','biochar','dataset','sqi','alert','reporting'))
                                    AND p.domain NOT IN ('iam'))
  OR (r.role_code = 'LAB_TECH'      AND (p.permission_code IN ('laboratory.read','laboratory.write','laboratory.approve',
                                                               'farm.read','experiment.read','biochar.read','biochar.write')))
  OR (r.role_code = 'FIELD_TECH'    AND (p.permission_code IN ('iot.read','iot.write','calibration.read','calibration.write',
                                                               'farm.read','laboratory.read','laboratory.write','alert.read','alert.write')))
  OR (r.role_code = 'DATA_ENGINEER' AND (p.action = 'READ' OR p.domain IN ('data_quality','dataset','ml','ota','iot'))
                                    AND p.domain NOT IN ('iam') AND p.permission_code <> 'ml.approve');

-- ---------- KPI nghiệm thu (giữ nguyên ngưỡng theo hồ sơ) ----------
INSERT INTO reporting.kpis (kpi_code, name_vi, domain, unit, comparator, target_value) VALUES
    ('DATA_COLLECTION_SUCCESS_PCT', 'Tỷ lệ dữ liệu thu thập thành công', 'iot',          '%',    'GTE', 90),
    ('TIMESTAMP_VALID_PCT',         'Tỷ lệ timestamp hợp lệ',            'iot',          '%',    'GTE', 90),
    ('ERROR_DUPLICATE_PCT',         'Tỷ lệ lỗi/trùng',                    'data_quality', '%',    'LTE', 5),
    ('MISSING_AFTER_QC_PCT',        'Tỷ lệ thiếu sau xử lý',              'data_quality', '%',    'LTE', 5),
    ('VALID_OBSERVATIONS',          'Số quan sát hợp lệ trong dataset',   'dataset',      'obs',  'GTE', 10000),
    ('ML_ACCURACY_PCT',             'Accuracy mô hình',                   'ml',           '%',    'GTE', 90),
    ('ML_PRECISION_PCT',            'Precision mô hình',                  'ml',           '%',    'GTE', 90),
    ('ML_RECALL_PCT',               'Recall mô hình',                     'ml',           '%',    'GTE', 80),
    ('ML_F1_PCT',                   'F1-score mô hình',                   'ml',           '%',    'GTE', 85),
    ('ML_INFERENCE_MS',             'Thời gian suy luận (p95)',           'ml',           'ms',   'LTE', 2000),
    ('OTA_SUCCESS_PCT',             'Tỷ lệ OTA thành công',               'ota',          '%',    'GTE', 95),
    ('OTA_UPDATE_MINUTES',          'Thời gian cập nhật OTA (max)',       'ota',          'phút', 'LTE', 10);

-- ---------- Luật QC cảm biến ----------
INSERT INTO data_quality.quality_rules (rule_code, name, rule_type, parameter_code, min_value, max_value, max_delta, severity) VALUES
    ('PH_RANGE',        'pH ngoài miền vật lý',          'RANGE',          'PH',        0,   14,   NULL, 'ERROR'),
    ('PH_PLAUSIBLE',    'pH bất thường cho đất canh tác','RANGE',          'PH',        3,   10,   NULL, 'WARN'),
    ('EC_RANGE',        'EC ngoài miền đo',              'RANGE',          'EC',        0,   20,   NULL, 'ERROR'),
    ('MOIST_RANGE',     'Độ ẩm ngoài 0–100%',            'RANGE',          'MOISTURE',  0,   100,  NULL, 'ERROR'),
    ('TEMP_RANGE',      'Nhiệt độ đất bất thường',       'RANGE',          'SOIL_TEMP', -5,  60,   NULL, 'ERROR'),
    ('N_RANGE',         'N ngoài miền đo',               'RANGE',          'N',         0,   1999, NULL, 'ERROR'),
    ('P_RANGE',         'P ngoài miền đo',               'RANGE',          'P',         0,   1999, NULL, 'ERROR'),
    ('K_RANGE',         'K ngoài miền đo',               'RANGE',          'K',         0,   1999, NULL, 'ERROR'),
    ('PH_SPIKE',        'pH thay đổi đột ngột',          'RATE_OF_CHANGE', 'PH',        NULL, NULL, 1.0, 'WARN'),
    ('MOIST_SPIKE',     'Độ ẩm thay đổi đột ngột',       'RATE_OF_CHANGE', 'MOISTURE',  NULL, NULL, 25,  'WARN');

-- ---------- Nhãn sức khỏe đất ----------
INSERT INTO dataset.labels (label_code, name_vi, class_order, description) VALUES
    ('VERY_GOOD', 'Rất tốt',    1, 'SQI ≥ 0.80'),
    ('GOOD',      'Tốt',        2, '0.60 ≤ SQI < 0.80'),
    ('FAIR',      'Trung bình', 3, '0.40 ≤ SQI < 0.60'),
    ('POOR',      'Kém',        4, 'SQI < 0.40');

-- ---------- SQI v1.0 (đề xuất ban đầu, cần hiệu chỉnh bằng PCA/chuyên gia) ----------
WITH d AS (
    INSERT INTO sqi.sqi_definitions (version_code, name, method, status, valid_from, description)
    VALUES ('SQI-v1.0', 'SQI tuyến tính có trọng số – cảm biến + lab', 'LINEAR_WEIGHTED', 'ACTIVE', DATE '2026-01-01',
            'Chỉ tiêu cảm biến pH, EC, ẩm, N, P, K và chỉ tiêu lab OC, CEC')
    RETURNING definition_id
),
ind AS (
    INSERT INTO sqi.sqi_indicators (definition_id, parameter_code, source, scoring_function,
                                    lower_limit, upper_limit, optimum_low, optimum_high)
    SELECT d.definition_id, x.* FROM d, (VALUES
        ('PH',       'SENSOR', 'OPTIMUM',        4.0,  8.5,  5.5, 7.0),
        ('EC',       'SENSOR', 'LESS_IS_BETTER', 0.0,  4.0,  NULL, NULL),
        ('MOISTURE', 'SENSOR', 'OPTIMUM',        5.0,  60.0, 20.0, 35.0),
        ('N',        'SENSOR', 'MORE_IS_BETTER', 10.0, 150.0, NULL, NULL),
        ('P',        'SENSOR', 'MORE_IS_BETTER', 5.0,  60.0,  NULL, NULL),
        ('K',        'SENSOR', 'MORE_IS_BETTER', 40.0, 250.0, NULL, NULL),
        ('OC',       'LAB',    'MORE_IS_BETTER', 0.5,  3.0,   NULL, NULL),
        ('CEC',      'LAB',    'MORE_IS_BETTER', 5.0,  25.0,  NULL, NULL)
    ) AS x(parameter_code, source, scoring_function, lower_limit, upper_limit, optimum_low, optimum_high)
    RETURNING definition_id, indicator_id, parameter_code
),
w AS (
    INSERT INTO sqi.sqi_weights (definition_id, indicator_id, weight, weighting_method)
    SELECT ind.definition_id, ind.indicator_id,
           CASE ind.parameter_code WHEN 'PH' THEN 0.18 WHEN 'EC' THEN 0.10 WHEN 'MOISTURE' THEN 0.12
                WHEN 'N' THEN 0.15 WHEN 'P' THEN 0.12 WHEN 'K' THEN 0.12
                WHEN 'OC' THEN 0.13 WHEN 'CEC' THEN 0.08 END,
           'EXPERT'
    FROM ind
    RETURNING definition_id
)
INSERT INTO sqi.sqi_classes (definition_id, class_code, min_value, max_value)
SELECT d.definition_id, c.* FROM d, (VALUES
    ('VERY_GOOD', 0.80, 1.0001), ('GOOD', 0.60, 0.80), ('FAIR', 0.40, 0.60), ('POOR', 0.0, 0.40)
) AS c(class_code, min_value, max_value);

-- ---------- Luật cảnh báo ----------
INSERT INTO alert.alert_rules (rule_code, name, source, parameter_code, condition, threshold_low, threshold_high,
                               class_values, window_minutes, severity, recommendation_category, recommendation_template) VALUES
    ('MOIST_LOW',  'Độ ẩm đất thấp',         'SENSOR', 'MOISTURE', 'LT',      15,   NULL, NULL, 60,  'HIGH',
        'IRRIGATION',    'Tưới bổ sung: độ ẩm trung bình 1 giờ qua {value}% < 15%.'),
    ('MOIST_HIGH', 'Độ ẩm đất quá cao',      'SENSOR', 'MOISTURE', 'GT',      NULL, 45,   NULL, 120, 'MEDIUM',
        'DRAINAGE',      'Kiểm tra thoát nước: độ ẩm {value}% > 45%.'),
    ('PH_OUT',     'pH ngoài khoảng tối ưu', 'SENSOR', 'PH',       'OUTSIDE', 5.0,  7.5,  NULL, 180, 'MEDIUM',
        'LIMING',        'pH {value} ngoài 5.0–7.5: cân nhắc bón vôi / điều chỉnh liều biochar.'),
    ('EC_HIGH',    'EC cao (nguy cơ mặn)',   'SENSOR', 'EC',       'GT',      NULL, 2.0,  NULL, 180, 'HIGH',
        'IRRIGATION',    'EC {value} dS/m > 2.0: rửa mặn, giảm phân bón hóa học.'),
    ('SQI_POOR',   'Sức khỏe đất kém',       'SQI',    NULL,       'CLASS_IN', NULL, NULL, '{POOR}', 1440, 'HIGH',
        'BIOCHAR_DOSE',  'SQI {value} ở mức Kém: xem xét tăng liều biochar làm giàu và bổ sung hữu cơ.'),
    ('ML_ANOMALY', 'AI phát hiện bất thường','ML',     NULL,       'ANOMALY', NULL, 0.8,  NULL, 60,  'MEDIUM',
        'DEVICE_MAINTENANCE', 'Mô hình phát hiện bất thường (score {value}): kiểm tra cảm biến hoặc hiện trường.'),
    ('NODE_OFFLINE','Sensor Node mất kết nối','DEVICE', NULL,      'OFFLINE', NULL, NULL, NULL, 60,  'CRITICAL',
        'DEVICE_MAINTENANCE', 'Node không gửi dữ liệu > 60 phút ({value} phút): kiểm tra nguồn/LoRa.');

-- >>>>> 17_db_roles.sql
-- =====================================================================
-- 17_db_roles.sql : tách quyền đọc/ghi theo domain ở mức database
-- Tạo role nhóm NOLOGIN; tài khoản đăng nhập thực tế được GRANT vào các role này.
-- Chạy bằng superuser / owner của database.
-- =====================================================================

DO $$
DECLARE
    s TEXT;
BEGIN
    FOREACH s IN ARRAY ARRAY['ref','iam','farm','experiment','biochar','iot','calibration','laboratory',
                             'data_quality','dataset','sqi','ml','ota','alert','reporting','audit'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = s || '_reader') THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', s || '_reader');
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = s || '_writer') THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', s || '_writer');
        END IF;
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I, %I', s, s || '_reader', s || '_writer');
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', s, s || '_reader');
        EXECUTE format('GRANT %I TO %I', s || '_reader', s || '_writer');
        EXECUTE format('GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', s, s || '_writer');
        EXECUTE format('GRANT USAGE ON ALL SEQUENCES IN SCHEMA %I TO %I', s, s || '_writer');
        EXECUTE format('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA %I TO %I', s, s || '_writer');
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT SELECT ON TABLES TO %I', s, s || '_reader');
        EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I GRANT INSERT, UPDATE, DELETE ON TABLES TO %I', s, s || '_writer');
    END LOOP;

    -- audit chỉ được thêm, không sửa/xóa
    EXECUTE 'REVOKE UPDATE, DELETE ON ALL TABLES IN SCHEMA audit FROM audit_writer';

    -- Role cho Edge Gateway: chỉ nạp dữ liệu và kết quả suy luận, cập nhật tiến độ OTA
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'edge_gateway') THEN
        CREATE ROLE edge_gateway NOLOGIN;
    END IF;
    GRANT USAGE ON SCHEMA ref, iot, calibration, data_quality, ml, ota TO edge_gateway;
    GRANT SELECT ON iot.sensors, iot.sensor_nodes, iot.sensor_configs, calibration.calibration_results,
                    ota.ota_packages TO edge_gateway;
    GRANT EXECUTE ON FUNCTION iot.ingest_reading(UUID, TIMESTAMPTZ, JSONB, BIGINT, NUMERIC, SMALLINT, NUMERIC, TIMESTAMPTZ)
        TO edge_gateway;
    GRANT INSERT ON ml.inference_results TO edge_gateway;
    GRANT SELECT, UPDATE (status, progress_pct, integrity_ok, compatibility_ok, error_message, finished_at)
        ON ota.ota_deployments TO edge_gateway;

    -- Role cho ứng dụng web/dashboard: đọc toàn bộ, ghi các domain nghiệp vụ
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_backend') THEN
        CREATE ROLE app_backend NOLOGIN;
    END IF;
    GRANT farm_writer, experiment_writer, biochar_writer, iot_writer, calibration_writer, laboratory_writer,
          data_quality_writer, dataset_writer, sqi_writer, ml_writer, ota_writer, alert_writer,
          reporting_writer, iam_writer, audit_writer, ref_reader TO app_backend;
END;
$$;

-- Ví dụ tạo tài khoản đăng nhập (đổi mật khẩu khi triển khai):
-- CREATE ROLE gw_site01 LOGIN PASSWORD '***' IN ROLE edge_gateway;
-- CREATE ROLE webapp    LOGIN PASSWORD '***' IN ROLE app_backend;

-- >>>>> 99_demo_seed.sql
-- =====================================================================
-- 99_demo_seed.sql : DỮ LIỆU DEMO (không chạy trên production)
-- 01 Gateway + 03 Sensor Node / 03 ô / 03 nghiệm thức, đo 15 phút/lần trong 45 ngày
-- => ~12.9k bản tin, có lỗi/trùng/thiếu giả lập để kiểm tra QC và KPI.
-- =====================================================================

SELECT setseed(0.42);

-- Partition theo tháng cho dữ liệu time-series (production: chạy định kỳ bằng pg_cron / job)
SELECT ref.ensure_monthly_partitions('iot.sensor_readings',     DATE '2026-07-01', 6);
SELECT ref.ensure_monthly_partitions('dataset.dataset_records', DATE '2026-07-01', 6);

DO $$
DECLARE
    v_org UUID; v_admin UUID; v_res UUID; v_lab UUID;
    v_site UUID; v_crop UUID; v_exp UUID; v_gw UUID;
    v_fs UUID; v_bc UUID; v_en UUID;
    v_t UUID[] := '{}'; v_plot UUID[] := '{}'; v_node UUID[] := '{}'; v_sensor UUID[] := '{}';
    v_season UUID; v_refdev UUID; v_sess UUID;
    v_start TIMESTAMPTZ := TIMESTAMPTZ '2026-08-01 00:00:00+07';
    v_days  INTEGER := 45;
    v_ts TIMESTAMPTZ; v_rec TIMESTAMPTZ;
    i INTEGER; j INTEGER; k INTEGER;
    v_ph NUMERIC; v_moist NUMERIC; v_ec NUMERIC; v_n NUMERIC; v_p NUMERIC; v_kk NUMERIC; v_temp NUMERIC;
    v_effect NUMERIC; v_hours NUMERIC; v_raw JSONB; v_seq BIGINT;
    v_stage RECORD;
    v_tmp UUID;
BEGIN
    -- ---------- tổ chức, người dùng ----------
    INSERT INTO iam.organizations (code, name) VALUES ('VIEN-NC', 'Viện nghiên cứu Đất & Môi trường')
        RETURNING organization_id INTO v_org;
    INSERT INTO iam.users (organization_id, username, email, full_name) VALUES
        (v_org, 'admin', 'admin@example.test', 'Quản trị viên') RETURNING user_id INTO v_admin;
    INSERT INTO iam.users (organization_id, username, email, full_name) VALUES
        (v_org, 'researcher01', 'researcher01@example.test', 'Nghiên cứu viên 01') RETURNING user_id INTO v_res;
    INSERT INTO iam.users (organization_id, username, email, full_name) VALUES
        (v_org, 'labtech01', 'labtech01@example.test', 'Kỹ thuật viên PTN 01') RETURNING user_id INTO v_lab;
    INSERT INTO iam.user_roles (user_id, role_id)
    SELECT u, r.role_id FROM (VALUES (v_admin, 'ADMIN'), (v_res, 'RESEARCHER'), (v_lab, 'LAB_TECH')) x(u, code)
    JOIN iam.roles r ON r.role_code = x.code;

    -- ---------- địa điểm, ô, cây trồng ----------
    INSERT INTO farm.sites (organization_id, site_code, name, province, district, latitude, longitude, elevation_m)
    VALUES (v_org, 'LN-01', 'Khu thí nghiệm vải Lục Ngạn', 'Bắc Giang', 'Lục Ngạn', 21.378600, 106.555900, 45)
    RETURNING site_id INTO v_site;

    FOR i IN 1..3 LOOP
        INSERT INTO farm.plots (site_id, plot_code, area_m2, soil_type, soil_texture, latitude, longitude, block_no)
        VALUES (v_site, 'P0' || i, 50, 'Feralit đỏ vàng', 'Thịt pha sét',
                21.378600 + i * 0.0002, 106.555900 + i * 0.0002, 1)
        RETURNING plot_id INTO v_tmp; v_plot[i] := v_tmp;
    END LOOP;

    INSERT INTO farm.crops (crop_code, name_vi, scientific_name, variety)
    VALUES ('VAI', 'Vải thiều', 'Litchi chinensis', 'Thanh Hà') RETURNING crop_id INTO v_crop;

    INSERT INTO experiment.growth_stages (crop_id, stage_code, name_vi, stage_order, typical_days_from_planting) VALUES
        (v_crop, 'POST_HARVEST', 'Phục hồi sau thu hoạch', 1, 0),
        (v_crop, 'SHOOT_1',      'Ra lộc thu đợt 1',        2, 15),
        (v_crop, 'SHOOT_2',      'Ra lộc thu đợt 2',        3, 30);

    -- ---------- biochar ----------
    INSERT INTO biochar.feedstock_batches (batch_code, feedstock_type, source_location, collected_on, mass_kg, moisture_pct, pretreatment)
    VALUES ('FS-2026-01', 'LITCHI_PRUNING', 'Vườn vải Lục Ngạn', DATE '2026-07-05', 500, 32.5, 'Phơi khô, băm 3–5 cm')
    RETURNING feedstock_batch_id INTO v_fs;
    INSERT INTO biochar.biochar_batches (batch_code, feedstock_batch_id, produced_on, reactor_type, pyrolysis_temp_c,
        residence_time_min, input_mass_kg, output_mass_kg, ph, ec_ds_m, carbon_pct, ash_pct, surface_area_m2_g,
        cec_cmol_kg, heavy_metals_mg_kg, safety_status)
    VALUES ('BC-2026-01', v_fs, DATE '2026-07-15', 'Lò yếm khí TLUD', 500, 90, 300, 96, 9.1, 1.8, 68.4, 9.2, 245,
            32.0, '{"Pb":2.1,"Cd":0.08,"As":0.6}', 'PASSED')
    RETURNING biochar_batch_id INTO v_bc;
    INSERT INTO biochar.enrichment_batches (batch_code, biochar_batch_id, enrichment_type, microbial_formula,
        nutrient_formula, ratio_desc, started_on, finished_on)
    VALUES ('EN-2026-01', v_bc, 'MIXED', 'Trichoderma + Bacillus subtilis', 'Phân chuồng hoai', 'Biochar:phân 1:1, 10^8 CFU/g',
            DATE '2026-07-16', DATE '2026-07-30')
    RETURNING enrichment_batch_id INTO v_en;
    INSERT INTO biochar.enrichment_results (enrichment_batch_id, parameter_code, value, unit, measured_on, pass_flag) VALUES
        (v_en, 'CFU_TRICHODERMA', 1.2e8, 'CFU/g', DATE '2026-07-30', true),
        (v_en, 'N_TOTAL',         1.35,  '%',     DATE '2026-07-30', true);

    -- ---------- thí nghiệm, nghiệm thức ----------
    INSERT INTO experiment.experiments (site_id, experiment_code, title, design_type, replicates, started_on,
                                        principal_investigator, status)
    VALUES (v_site, 'EXP-BC-2026', 'Ảnh hưởng của biochar phụ phẩm vải đến sức khỏe đất', 'RCBD', 1,
            DATE '2026-08-01', v_res, 'RUNNING')
    RETURNING experiment_id INTO v_exp;

    INSERT INTO experiment.treatments (experiment_id, treatment_code, name, biochar_dose_kg_m2, control_flag)
    VALUES (v_exp, 'T0', 'Đối chứng (không biochar)', 0, true) RETURNING treatment_id INTO v_tmp; v_t[1] := v_tmp;
    INSERT INTO experiment.treatments (experiment_id, treatment_code, name, biochar_dose_kg_m2, biochar_batch_id)
    VALUES (v_exp, 'T1', 'Biochar 1.0 kg/m²', 1.0, v_bc) RETURNING treatment_id INTO v_tmp; v_t[2] := v_tmp;
    INSERT INTO experiment.treatments (experiment_id, treatment_code, name, biochar_dose_kg_m2, biochar_batch_id,
                                       enrichment_batch_id, microbial_formula)
    VALUES (v_exp, 'T2', 'Biochar làm giàu 1.0 kg/m²', 1.0, v_bc, v_en, 'Trichoderma + B. subtilis')
    RETURNING treatment_id INTO v_tmp; v_t[3] := v_tmp;

    FOR i IN 1..3 LOOP
        INSERT INTO farm.crop_seasons (plot_id, crop_id, season_code, planted_on)
        VALUES (v_plot[i], v_crop, '2026-THU', DATE '2026-07-25') RETURNING crop_season_id INTO v_season;

        INSERT INTO experiment.treatment_applications (treatment_id, plot_id, crop_season_id, replicate_no,
                                                       applied_on, effective_from, actual_dose_kg_m2, applied_by)
        VALUES (v_t[i], v_plot[i], v_season, 1, DATE '2026-07-31', v_start, CASE WHEN i = 1 THEN 0 ELSE 1.0 END, v_res);

        FOR v_stage IN SELECT * FROM experiment.growth_stages WHERE crop_id = v_crop ORDER BY stage_order LOOP
            INSERT INTO experiment.plot_growth_stages (crop_season_id, growth_stage_id, started_at, ended_at, observed_by)
            VALUES (v_season, v_stage.growth_stage_id,
                    v_start + (v_stage.stage_order - 1) * INTERVAL '15 days',
                    CASE WHEN v_stage.stage_order < 3 THEN v_start + v_stage.stage_order * INTERVAL '15 days' END,
                    v_res);
        END LOOP;
    END LOOP;

    -- ---------- thiết bị IoT ----------
    INSERT INTO iot.gateways (site_id, gateway_code, hardware_model, serial_no, firmware_version, lorawan_gateway_eui,
                              network_backhaul, local_buffer_capacity_mb, latitude, longitude, installed_at, last_seen_at)
    VALUES (v_site, 'GW01', 'Raspberry Pi 5 + RAK2287', 'RPI5-0001', '1.0.0', 'AA555A0000000001',
            '4G', 2048, 21.378900, 106.556200, v_start - INTERVAL '3 days', v_start + v_days * INTERVAL '1 day')
    RETURNING gateway_id INTO v_gw;

    FOR i IN 1..3 LOOP
        INSERT INTO iot.sensor_nodes (gateway_id, plot_id, node_code, dev_eui, mcu_model, firmware_version,
                                      power_source, sampling_interval_s, installed_at)
        VALUES (v_gw, v_plot[i], 'N0' || i, '70B3D57ED00000' || lpad(i::text, 2, '0'), 'ESP32-S3 + SX1276', '0.9.0',
                'SOLAR', 900, v_start - INTERVAL '2 days')
        RETURNING node_id INTO v_tmp; v_node[i] := v_tmp;
        INSERT INTO iot.sensors (node_id, sensor_code, sensor_model, serial_no, interface, measured_parameters,
                                 install_depth_cm, installed_at)
        VALUES (v_node[i], 'S0' || i, 'Soil 7-in-1 RS485 (pH/EC/ẩm/nhiệt/NPK)', 'SN-7IN1-00' || i, 'RS485',
                '{PH,EC,MOISTURE,SOIL_TEMP,N,P,K}', 20, v_start - INTERVAL '2 days')
        RETURNING sensor_id INTO v_tmp; v_sensor[i] := v_tmp;
        INSERT INTO iot.sensor_configs (node_id, sensor_id, config_version, sampling_interval_s, lora_spreading_factor,
                                        tx_power_dbm, edge_thresholds, valid_from, applied_status, created_by)
        VALUES (v_node[i], v_sensor[i], 1, 900, 9, 14, '{"MOISTURE":{"min":15,"max":45}}',
                v_start - INTERVAL '2 days', 'APPLIED', v_admin);
    END LOOP;

    -- ---------- hiệu chuẩn (pH và độ ẩm, 3 mức × 2 lần lặp) ----------
    INSERT INTO calibration.reference_devices (device_code, name, manufacturer, model, parameters, certificate_no, certified_until)
    VALUES ('REF-PH-01', 'Máy đo pH/EC để bàn', 'Hanna', 'HI5522', '{PH,EC}', 'KD-2026-0153', DATE '2027-06-30')
    RETURNING reference_device_id INTO v_refdev;

    FOR i IN 1..3 LOOP
        INSERT INTO calibration.calibration_sessions (sensor_id, reference_device_id, session_type, performed_at, performed_by, ambient_temp_c)
        VALUES (v_sensor[i], v_refdev, 'LAB', v_start - INTERVAL '2 days', v_admin, 26.5)
        RETURNING session_id INTO v_sess;
        FOR j IN 1..2 LOOP
            INSERT INTO calibration.calibration_points (session_id, parameter_code, reference_value, sensor_value, replicate_no)
            VALUES (v_sess, 'PH', 4.01, 4.01 + 0.15 + (random() - 0.5) * 0.04, j),
                   (v_sess, 'PH', 6.86, 6.86 + 0.12 + (random() - 0.5) * 0.04, j),
                   (v_sess, 'PH', 9.18, 9.18 + 0.08 + (random() - 0.5) * 0.04, j),
                   (v_sess, 'MOISTURE', 10, 11.4 + (random() - 0.5) * 0.6, j),
                   (v_sess, 'MOISTURE', 30, 32.6 + (random() - 0.5) * 0.6, j),
                   (v_sess, 'MOISTURE', 50, 53.8 + (random() - 0.5) * 0.6, j);
        END LOOP;
        PERFORM calibration.compute_results(v_sess);
    END LOOP;

    -- ---------- dữ liệu cảm biến ----------
    FOR i IN 1..3 LOOP
        v_effect := CASE i WHEN 1 THEN 0 WHEN 2 THEN 0.6 ELSE 1.0 END;   -- hiệu ứng nghiệm thức
        v_seq := 0;
        FOR k IN 0 .. v_days * 96 - 1 LOOP
            v_ts := v_start + k * INTERVAL '15 minutes';
            v_seq := v_seq + 1;
            CONTINUE WHEN random() < 0.03;                               -- ~3% mất gói
            v_hours := EXTRACT(EPOCH FROM v_ts - v_start) / 3600;
            v_moist := 22 + 4 * v_effect + 6 * sin(v_hours / 24 * 2 * pi() / 7) - 1.5 * sin(v_hours / 24 * 2 * pi())
                       + (random() - 0.5) * 2;
            v_ph    := 4.9 + 0.9 * v_effect * LEAST(v_hours / 24 / 20, 1) + (random() - 0.5) * 0.2;
            v_ec    := 0.35 + 0.15 * v_effect + (random() - 0.5) * 0.08;
            v_temp  := 26 + 3 * sin((v_hours - 9) / 24 * 2 * pi()) + (random() - 0.5);
            v_n     := 38 + 45 * v_effect + (random() - 0.5) * 10;
            v_p     := 14 + 18 * v_effect + (random() - 0.5) * 5;
            v_kk    := 95 + 70 * v_effect + (random() - 0.5) * 20;
            -- giả lập lỗi cảm biến (~1%)
            IF random() < 0.006 THEN v_moist := 120; END IF;
            IF random() < 0.004 THEN v_ph := 15.2; END IF;
            v_raw := jsonb_build_object('PH', round(v_ph + 0.12, 2), 'EC', round(v_ec, 3),
                                        'MOISTURE', round(v_moist * 1.06 + 0.8, 2),   -- trước hiệu chuẩn
                                        'SOIL_TEMP', round(v_temp, 2),
                                        'N', round(v_n, 1), 'P', round(v_p, 1), 'K', round(v_kk, 1));
            v_rec := v_ts + INTERVAL '20 seconds';
            IF random() < 0.003 THEN v_rec := v_ts - INTERVAL '2 hours'; END IF;   -- đồng hồ node lệch
            PERFORM iot.ingest_reading(v_sensor[i], v_ts, v_raw, v_seq, 3.9::numeric, -97::smallint, 7.5, v_rec);
            IF random() < 0.005 THEN                                     -- gửi lại (store-and-forward)
                PERFORM iot.ingest_reading(v_sensor[i], v_ts, v_raw, v_seq, 3.9::numeric, -97::smallint, 7.5,
                                           v_rec + INTERVAL '10 minutes');
            END IF;
        END LOOP;
    END LOOP;

    -- ---------- phòng thí nghiệm: mẫu hàng tuần ----------
    INSERT INTO laboratory.lab_methods (method_code, parameter_code, name, standard_ref, unit) VALUES
        ('M-PH',  'PH',  'pH KCl',              'TCVN 5979',  'pH'),
        ('M-EC',  'EC',  'EC dịch chiết 1:5',   'TCVN 6650',  'dS/m'),
        ('M-N',   'N',   'N dễ tiêu',           'TCVN 5255',  'mg/kg'),
        ('M-P',   'P',   'P dễ tiêu Bray',      'TCVN 8942',  'mg/kg'),
        ('M-K',   'K',   'K dễ tiêu',           'TCVN 8662',  'mg/kg'),
        ('M-OC',  'OC',  'Walkley-Black',       'TCVN 8941',  '%'),
        ('M-CEC', 'CEC', 'Amoni axetat pH7',    'TCVN 8568',  'cmol/kg');

    FOR i IN 1..3 LOOP
        v_effect := CASE i WHEN 1 THEN 0 WHEN 2 THEN 0.6 ELSE 1.0 END;
        FOR j IN 0..6 LOOP
            WITH s AS (
                INSERT INTO laboratory.soil_samples (sample_code, plot_id, sample_type, sampled_at, depth_from_cm,
                                                     depth_to_cm, near_node_id, composite_of, collected_by, received_at, status)
                VALUES (format('SS-P0%s-W%s', i, j + 1), v_plot[i], 'SOIL',
                        v_start + j * INTERVAL '7 days' + INTERVAL '33 hours', 0, 20, v_node[i], 5, v_lab,
                        v_start + j * INTERVAL '7 days' + INTERVAL '40 hours', 'COMPLETED')
                RETURNING sample_id
            )
            INSERT INTO laboratory.lab_results (sample_id, parameter_code, value, unit, method_id, analyzed_at,
                                                analyst_id, approved_by, result_status)
            SELECT s.sample_id, m.parameter_code,
                   round(CASE m.parameter_code
                       WHEN 'PH'  THEN 4.9 + 0.9 * v_effect * LEAST(j * 7 / 20.0, 1)
                       WHEN 'EC'  THEN 0.35 + 0.15 * v_effect
                       WHEN 'N'   THEN 38 + 45 * v_effect
                       WHEN 'P'   THEN 14 + 18 * v_effect
                       WHEN 'K'   THEN 95 + 70 * v_effect
                       WHEN 'OC'  THEN 1.1 + 1.2 * v_effect + j * 0.03 * v_effect
                       WHEN 'CEC' THEN 8 + 7 * v_effect END * (1 + (random() - 0.5) * 0.06)::numeric, 3),
                   m.unit, m.method_id, v_start + j * INTERVAL '7 days' + INTERVAL '3 days', v_lab, v_res, 'APPROVED'
            FROM s CROSS JOIN laboratory.lab_methods m;
        END LOOP;
    END LOOP;
END;
$$;

-- ---------- QC toàn bộ dữ liệu ----------
SELECT data_quality.run_sensor_checks(TIMESTAMPTZ '2026-08-01 00:00+07', TIMESTAMPTZ '2026-09-15 00:00+07');

-- ---------- Dataset tham chiếu + SQI + nhãn ----------
DO $$
DECLARE
    v_ds UUID; v_ver UUID; v_def UUID;
BEGIN
    INSERT INTO dataset.datasets (dataset_code, name, purpose, site_id, experiment_id, owner_id)
    SELECT 'REF-LN-2026', 'Bộ dữ liệu tham chiếu Lục Ngạn 2026', 'REFERENCE', s.site_id, e.experiment_id, u.user_id
    FROM farm.sites s, experiment.experiments e, iam.users u
    WHERE s.site_code = 'LN-01' AND e.experiment_code = 'EXP-BC-2026' AND u.username = 'researcher01'
    RETURNING dataset_id INTO v_ds;

    INSERT INTO dataset.dataset_versions (dataset_id, version_no, time_from, time_to, aggregation, split_strategy)
    VALUES (v_ds, 1, TIMESTAMPTZ '2026-08-01 00:00+07', TIMESTAMPTZ '2026-09-15 00:00+07', 'RAW', 'BY_TIME')
    RETURNING dataset_version_id INTO v_ver;

    PERFORM dataset.build_version(v_ver);
    SELECT definition_id INTO v_def FROM sqi.sqi_definitions WHERE version_code = 'SQI-v1.0';
    PERFORM sqi.calculate_daily(v_def, v_ver);
    PERFORM sqi.assign_labels(v_def, v_ver);
    PERFORM dataset.freeze_version(v_ver);
END;
$$;

-- ---------- Embedded ML: model, metrics, OTA, suy luận ----------
DO $$
DECLARE
    v_ver UUID; v_m1 UUID; v_mv1 UUID; v_m2 UUID; v_mv2 UUID;
    v_pkg UUID; v_fw UUID; v_dep UUID; v_gw UUID; v_res UUID;
    v_t0 TIMESTAMPTZ := TIMESTAMPTZ '2026-09-08 09:00+07';
    r RECORD;
BEGIN
    SELECT dataset_version_id INTO v_ver FROM dataset.dataset_versions WHERE status = 'FROZEN' LIMIT 1;
    SELECT gateway_id INTO v_gw FROM iot.gateways WHERE gateway_code = 'GW01';
    SELECT user_id INTO v_res FROM iam.users WHERE username = 'researcher01';

    INSERT INTO ml.models (model_code, name, task_type, target, algorithm, owner_id)
    VALUES ('SOIL-HEALTH-CLS', 'Phân loại sức khỏe đất', 'CLASSIFICATION', 'SOIL_HEALTH_CLASS', 'RandomForest→TFLite', v_res)
    RETURNING model_id INTO v_m1;
    INSERT INTO ml.model_versions (model_id, version, dataset_version_id, framework, quantization, artifact_uri,
                                   artifact_sha256, size_kb, input_schema, target_hardware, trained_at)
    VALUES (v_m1, '1.0.0', v_ver, 'TFLITE', 'INT8', 's3://models/soil-health-cls/1.0.0/model.tflite',
            repeat('a1', 32), 184.5, '{"features":["ph","ec","soil_moisture","soil_temperature","n","p","k"]}',
            'Raspberry Pi 5', v_t0 - INTERVAL '2 days')
    RETURNING model_version_id INTO v_mv1;
    INSERT INTO ml.model_metrics (model_version_id, dataset_version_id, split, metric_name, metric_value) VALUES
        (v_mv1, v_ver, 'TEST', 'ACCURACY', 0.934), (v_mv1, v_ver, 'TEST', 'PRECISION', 0.921),
        (v_mv1, v_ver, 'TEST', 'RECALL', 0.887),   (v_mv1, v_ver, 'TEST', 'F1', 0.903),
        (v_mv1, v_ver, 'VAL',  'ACCURACY', 0.941), (v_mv1, v_ver, 'VAL',  'F1', 0.915);
    PERFORM ml.approve_model_version(v_mv1, v_res);

    INSERT INTO ml.models (model_code, name, task_type, target, algorithm, owner_id)
    VALUES ('SENSOR-ANOMALY', 'Phát hiện bất thường cảm biến', 'ANOMALY_DETECTION', 'SENSOR_ANOMALY', 'Autoencoder', v_res)
    RETURNING model_id INTO v_m2;
    INSERT INTO ml.model_versions (model_id, version, dataset_version_id, framework, quantization, artifact_uri,
                                   artifact_sha256, size_kb, target_hardware, trained_at)
    VALUES (v_m2, '0.3.0', v_ver, 'TFLITE', 'INT8', 's3://models/sensor-anomaly/0.3.0/model.tflite',
            repeat('b2', 32), 96.0, 'Raspberry Pi 5', v_t0 - INTERVAL '2 days')
    RETURNING model_version_id INTO v_mv2;
    INSERT INTO ml.model_metrics (model_version_id, dataset_version_id, split, metric_name, metric_value) VALUES
        (v_mv2, v_ver, 'TEST', 'ACCURACY', 0.912), (v_mv2, v_ver, 'TEST', 'PRECISION', 0.903),
        (v_mv2, v_ver, 'TEST', 'RECALL', 0.842),   (v_mv2, v_ver, 'TEST', 'F1', 0.871);

    -- OTA: gói model -> gateway
    INSERT INTO ota.ota_packages (package_code, package_type, model_version_id, version, artifact_uri, sha256,
                                  size_bytes, compatible_hardware, status, created_by)
    VALUES ('PKG-SHC-1.0.0', 'MODEL', v_mv1, '1.0.0', 's3://ota/soil-health-cls-1.0.0.tar.gz', repeat('c3', 32),
            201000, '{"Raspberry Pi 5"}', 'RELEASED', v_res)
    RETURNING package_id INTO v_pkg;
    INSERT INTO ota.ota_deployments (package_id, gateway_id, initiated_by) VALUES (v_pkg, v_gw, v_res)
        RETURNING deployment_id INTO v_dep;
    UPDATE ota.ota_deployments SET status = 'DOWNLOADING', started_at = v_t0, progress_pct = 10 WHERE deployment_id = v_dep;
    UPDATE ota.ota_deployments SET progress_pct = 80 WHERE deployment_id = v_dep;
    UPDATE ota.ota_deployments SET status = 'VERIFY', integrity_ok = true, compatibility_ok = true WHERE deployment_id = v_dep;
    UPDATE ota.ota_deployments SET status = 'ACTIVE', finished_at = v_t0 + INTERVAL '4 minutes 20 seconds' WHERE deployment_id = v_dep;

    -- OTA: firmware cho 3 node
    INSERT INTO ota.ota_packages (package_code, package_type, version, artifact_uri, sha256, size_bytes,
                                  compatible_hardware, status, created_by)
    VALUES ('PKG-FW-NODE-1.0.0', 'FIRMWARE', '1.0.0', 's3://ota/node-fw-1.0.0.bin', repeat('d4', 32), 1450000,
            '{"ESP32-S3 + SX1276"}', 'RELEASED', v_res)
    RETURNING package_id INTO v_fw;
    FOR r IN SELECT node_id, row_number() OVER (ORDER BY node_code) rn FROM iot.sensor_nodes LOOP
        INSERT INTO ota.ota_deployments (package_id, gateway_id, node_id, initiated_by)
        VALUES (v_fw, v_gw, r.node_id, v_res) RETURNING deployment_id INTO v_dep;
        UPDATE ota.ota_deployments SET status = 'DOWNLOADING', started_at = v_t0 + r.rn * INTERVAL '1 hour' WHERE deployment_id = v_dep;
        UPDATE ota.ota_deployments SET status = 'VERIFY', integrity_ok = true, compatibility_ok = true WHERE deployment_id = v_dep;
        UPDATE ota.ota_deployments SET status = 'ACTIVE',
               finished_at = v_t0 + r.rn * INTERVAL '1 hour' + (5 + r.rn) * INTERVAL '1 minute' WHERE deployment_id = v_dep;
    END LOOP;

    -- Suy luận tại Edge: mỗi giờ, mỗi ô, 7 ngày cuối
    INSERT INTO ml.inference_results (model_version_id, gateway_id, node_id, plot_id, inferred_at, task_type,
                                      input_reading_id, input_features, prediction, predicted_label, confidence, latency_ms)
    SELECT v_mv1, v_gw, sr.node_id, sr.plot_id, sr.measured_at + INTERVAL '5 seconds', 'CLASSIFICATION',
           sr.reading_id,
           jsonb_build_object('ph', sr.ph, 'ec', sr.ec, 'soil_moisture', sr.soil_moisture, 'n', sr.n, 'p', sr.p, 'k', sr.k),
           jsonb_build_object('class', s.health_class), s.health_class,
           round((0.80 + random() * 0.19)::numeric, 4), round((250 + random() * 900)::numeric, 2)
    FROM iot.sensor_readings sr
    JOIN sqi.sqi_scores s ON s.plot_id = sr.plot_id AND sr.measured_at >= s.period_start AND sr.measured_at < s.period_end
    WHERE sr.measured_at >= v_t0 AND sr.quality_status = 'VALID' AND EXTRACT(MINUTE FROM sr.measured_at) = 0;

    INSERT INTO ml.inference_results (model_version_id, gateway_id, node_id, plot_id, inferred_at, task_type,
                                      input_reading_id, prediction, anomaly_score, is_anomaly, latency_ms)
    SELECT v_mv2, v_gw, sr.node_id, sr.plot_id, sr.measured_at + INTERVAL '3 seconds', 'ANOMALY_DETECTION', sr.reading_id,
           jsonb_build_object('anomaly', sr.quality_status <> 'VALID'),
           CASE WHEN sr.quality_status <> 'VALID' THEN 0.9 + random() * 0.09 ELSE random() * 0.3 END,
           sr.quality_status <> 'VALID', round((120 + random() * 300)::numeric, 2)
    FROM iot.sensor_readings sr
    WHERE sr.measured_at >= v_t0;
END;
$$;

-- ---------- Cảnh báo tại vài thời điểm ----------
SELECT alert.evaluate_rules(TIMESTAMPTZ '2026-08-03 14:00+07');
SELECT alert.evaluate_rules(TIMESTAMPTZ '2026-08-20 14:00+07');
SELECT alert.evaluate_rules(TIMESTAMPTZ '2026-09-14 14:00+07');

-- ---------- Kinh tế (giả định) ----------
INSERT INTO reporting.economic_results (experiment_id, treatment_id, plot_id, yield_kg_m2, price_vnd_kg,
       cost_biochar_vnd_ha, cost_fertilizer_vnd_ha, cost_labor_vnd_ha, cost_other_vnd_ha, carbon_sequestered_kg_ha)
SELECT t.experiment_id, t.treatment_id, ta.plot_id,
       CASE t.treatment_code WHEN 'T0' THEN 0.95 WHEN 'T1' THEN 1.10 ELSE 1.22 END,
       25000,
       CASE t.treatment_code WHEN 'T0' THEN 0 ELSE 15000000 END
         + CASE t.treatment_code WHEN 'T2' THEN 4000000 ELSE 0 END,
       12000000, 30000000, 8000000,
       CASE t.treatment_code WHEN 'T0' THEN 0 ELSE 6800 END
FROM experiment.treatments t
JOIN experiment.treatment_applications ta ON ta.treatment_id = t.treatment_id;

SELECT reporting.snapshot_acceptance(TIMESTAMPTZ '2026-08-01 00:00+07', TIMESTAMPTZ '2026-09-15 00:00+07');

