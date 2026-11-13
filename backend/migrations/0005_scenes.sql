-- Ngữ cảnh (scene): nhóm hành động bật/tắt thiết bị, chạy bằng tay hoặc TỰ KÍCH HOẠT vào khung giờ đã chọn.
-- actions: [{"device_id": "<uuid>", "payload": {"state_1": "ON"}}] — không có FK tới devices (thiết bị bị xoá thì
-- hành động đó bị bỏ qua khi chạy); payload đã được kiểm tra bằng đúng bộ whitelist của lệnh điều khiển.
-- Tự kích hoạt: auto_time tính theo múi giờ căn hộ (homes.timezone); auto_days theo ISO: 1 = thứ Hai … 7 = Chủ nhật.
CREATE TABLE scenes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id      uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  name         text NOT NULL,
  icon         text NOT NULL DEFAULT 'home',
  actions      jsonb NOT NULL DEFAULT '[]',
  auto_enabled boolean NOT NULL DEFAULT false,
  auto_time    time,
  auto_days    smallint[] NOT NULL DEFAULT '{1,2,3,4,5,6,7}',
  last_run_at  timestamptz,   -- lần tự chạy gần nhất; với 'missed' là thời điểm đã định
  last_status  text,          -- running | ok | partial | failed | missed
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT auto_enabled OR auto_time IS NOT NULL),
  CHECK (cardinality(auto_days) BETWEEN 1 AND 7)
);
CREATE INDEX scenes_home_idx ON scenes (home_id);
