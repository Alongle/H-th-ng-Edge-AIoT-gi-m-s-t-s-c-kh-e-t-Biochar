# ml/ – Embedded ML (TV6)

| Bước | Notebook | Kết quả |
|---|---|---|
| 1. Huấn luyện | [`01_train_models.ipynb`](01_train_models.ipynb) | Model scikit-learn, version `1.1.0` |
| 2. Chuyển TFLite | [`02_convert_tflite.ipynb`](02_convert_tflite.ipynb) | File `.tflite` + code chạy trên gateway, version `1.2.0` |

Cả hai notebook đã chạy sẵn kết quả, GitHub hiển thị luôn, không cần chạy lại.

| Mô hình | `model_code` | Thuật toán | File chạy trên gateway |
|---|---|---|---|
| Phân loại sức khỏe đất | `SOIL-HEALTH-CLS` | Logistic Regression (7 chỉ số cảm biến) | `soil_health_cls.tflite` (INT8, ~2,6 KB) |
| Phát hiện bất thường cảm biến | `SENSOR-ANOMALY` | Robust z-score (MAD), so với trung vị 8 bản tin trước | `sensor_anomaly.tflite` (FP32, ~1,3 KB) |

Trên tập test, cả hai đều đạt toàn bộ tiêu chí nghiệm thu, và bản TFLite cho kết quả giống hệt bản gốc. **Lưu ý:** dữ liệu demo là giả lập và rất dễ, xem phần *Kết luận* của notebook 1.

## Cấu trúc

```
ml/
├── 01_train_models.ipynb     bước 1: huấn luyện + đánh giá
├── 02_convert_tflite.ipynb   bước 2: chuyển TFLite, kiểm tra bằng code gateway, đo độ trễ
├── edge/edge_runtime.py      code chạy 2 mô hình trên gateway (TV2 dùng khi tích hợp)
├── export_data.mjs           xuất dữ liệu từ database demo ra data/*.csv
├── queries/*.sql             câu SQL lấy dữ liệu (dùng chung cho export và PostgreSQL thật)
├── data/*.csv                dữ liệu đã xuất
├── models/
│   ├── *.joblib              mô hình scikit-learn (bước 1)
│   ├── *.tflite              mô hình TFLite (bước 2) – file sẽ gửi xuống gateway qua OTA
│   └── *.json                mô tả đầu vào/đầu ra, ngưỡng, tham số MAD
└── output/
    ├── metrics.json, metrics_tflite.json
    ├── register_models.sql   đăng ký version 1.1.0 (SKLEARN)
    └── register_tflite.sql   đăng ký version 1.2.0 (TFLITE)
```

## Chạy mô hình trên gateway

`edge_runtime.py` chỉ cần `numpy` và một trình chạy TFLite. Trên Raspberry Pi nên dùng `ai-edge-litert`, nhẹ hơn nhiều so với cài cả TensorFlow.

```bash
pip install numpy ai-edge-litert
```
```bash
python ml/edge/edge_runtime.py ml/models ml/data/readings.csv --limit 5
```

Dùng trong code Python của gateway:

```python
from edge_runtime import EdgeModels
models = EdgeModels('ml/models')
out = models.infer({'sensor_code': 'S01', 'ph': 5.1, 'ec': 0.4, 'soil_moisture': 27,
                    'soil_temperature': 26, 'n': 60, 'p': 25, 'k': 140})
# out['anomaly'] -> anomaly_score, is_anomaly ; out['health'] -> predicted_label, confidence
```

- Gateway phải gọi `infer()` **lần lượt từng bản tin, theo thứ tự thời gian của từng cảm biến**, vì mô hình bất thường cần nhớ 8 bản tin trước.
- Nếu bản tin bị đánh giá là bất thường, kết quả phân loại sức khỏe đất của bản tin đó sẽ để trống, để không kết luận từ số đo sai.

## Chạy lại các notebook

**1. Lấy dữ liệu.** Chọn một trong hai cách:
- Dùng database demo: chạy từ thư mục `edge_aiot_biochar_db`. Lệnh `npm install` trong `viewer` chỉ cần chạy một lần.
  ```bash
  cd viewer && npm install && cd ..
  ```
  ```bash
  node ml/export_data.mjs
  ```
- Dùng PostgreSQL thật: cài `psycopg` và đặt biến `DATABASE_URL`. Notebook sẽ đọc thẳng database.

**2. Môi trường Python.**
- Notebook 1 cần `pandas`, `numpy`, `scikit-learn`, `matplotlib`, `joblib`, `jupyter`.
- Notebook 2 cần thêm **TensorFlow ≥ 2.16**.
- Trên Windows, cài TensorFlow vào venv ở **đường dẫn ngắn**. Python bản Microsoft Store nằm trong thư mục có đường dẫn rất dài, nên vài file của TensorFlow vượt giới hạn 260 ký tự và cài bị lỗi.
  ```bash
  python -m venv C:\Users\<tên>\.tfenv
  ```
  ```bash
  C:\Users\<tên>\.tfenv\Scripts\pip install tensorflow scikit-learn pandas matplotlib joblib jupyter
  ```
  Sau đó chọn kernel Python của `.tfenv` khi mở notebook.

**3. Ghi kết quả vào database.** Cả hai file đều chạy lại nhiều lần vẫn an toàn (upsert):
```bash
psql -d edge_aiot_biochar -f ml/output/register_models.sql
```
```bash
psql -d edge_aiot_biochar -f ml/output/register_tflite.sql
```
Xem kết quả bằng `SELECT * FROM ml.v_model_acceptance;`. Duyệt một version bằng `SELECT ml.approve_model_version('<model_version_id>', '<user_id>');`.

## Lưu ý

- Metrics của version `1.0.0` / `0.3.0` trong `sql/99_demo_seed.sql` là **số gõ tay** để có dữ liệu mẫu. Metrics thật là của version `1.1.0` và `1.2.0`.
- Độ trễ được đo trên máy tính (CPU x86): dưới 1 ms mỗi mẫu. Khi có bộ giả lập gateway (TV2) hoặc Raspberry Pi, chạy lại `edge_runtime.py` trên đó và ghi metric với `environment = 'EDGE'`.
- TFLite trên Windows không mở được file nằm trong thư mục có dấu tiếng Việt khi truyền đường dẫn trực tiếp. `edge_runtime.py` đã xử lý bằng cách tự đọc nội dung file rồi đưa vào TFLite.
