# ml/ – Embedded ML (TV6)

Bước 1: huấn luyện hai mô hình chạy tại Edge Gateway từ dữ liệu trong database.

| Mô hình | `model_code` | Thuật toán được chọn | Kích thước |
|---|---|---|---|
| Phân loại sức khỏe đất | `SOIL-HEALTH-CLS` | Logistic Regression (7 chỉ số cảm biến) | ~1 KB |
| Phát hiện bất thường cảm biến | `SENSOR-ANOMALY` | Robust z-score (MAD) trên độ lệch so với trung vị 8 bản tin trước | ~0,2 KB |

Kết quả chi tiết, so sánh các mô hình và **giới hạn của dữ liệu demo** nằm trong notebook [`01_train_models.ipynb`](01_train_models.ipynb). GitHub hiển thị sẵn kết quả, không cần chạy lại.

## Cấu trúc

```
ml/
├── 01_train_models.ipynb   notebook huấn luyện + đánh giá (đã chạy sẵn kết quả)
├── export_data.mjs         xuất dữ liệu từ database demo ra data/*.csv
├── queries/*.sql           câu SQL lấy dữ liệu (dùng chung cho export và cho PostgreSQL thật)
├── data/*.csv              dữ liệu đã xuất
├── models/*.joblib, *.json mô hình và mô tả đầu vào/đầu ra
└── output/
    ├── metrics.json        toàn bộ metrics
    └── register_models.sql ghi model version 1.1.0 + metrics thật vào ml.model_versions / ml.model_metrics
```

## Chạy lại

Cần Python 3.10+ với `pandas`, `numpy`, `scikit-learn`, `matplotlib`, `joblib`, `jupyter`.

**1. Lấy dữ liệu.** Chọn một trong hai cách:
- Dùng database demo, không cần PostgreSQL: chạy từ thư mục `edge_aiot_biochar_db`. Lệnh `npm install` trong `viewer` chỉ cần chạy một lần.
  ```bash
  cd viewer && npm install && cd ..
  ```
  ```bash
  node ml/export_data.mjs
  ```
- Dùng PostgreSQL thật: cài thêm `psycopg`, đặt biến `DATABASE_URL`. Notebook sẽ đọc thẳng database bằng các file trong `queries/`.
  ```bash
  export DATABASE_URL="postgresql://user:pass@localhost:5432/edge_aiot_biochar"
  ```

**2. Mở và chạy notebook:** `ml/01_train_models.ipynb`, chạy *Run All*.

**3. Ghi kết quả vào database:**
```bash
psql -d edge_aiot_biochar -f ml/output/register_models.sql
```
File này chạy lại nhiều lần vẫn an toàn (upsert). Sau đó `ml.v_model_acceptance` sẽ hiện version `1.1.0` với metrics thật. Duyệt model bằng `SELECT ml.approve_model_version('<model_version_id>', '<user_id>');`.

## Lưu ý

- Metrics của version `1.0.0` / `0.3.0` trong `sql/99_demo_seed.sql` là **số gõ tay** để có dữ liệu mẫu. Metrics thật là của version `1.1.0` do notebook sinh ra.
- Điểm 100% trên dữ liệu demo là do dữ liệu giả lập dễ, xem phần *Kết luận* trong notebook. Cần đánh giá lại khi có dữ liệu thật.
- Độ trễ trong notebook được đo bằng scikit-learn trên máy tính. Độ trễ trên gateway sẽ đo ở **bước 2** (chuyển sang TFLite).
