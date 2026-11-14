-- Cảnh báo cảm biến gắn với ngữ cảnh + thông báo đẩy.
--  * scenes.alert_devices : cảm biến (hiện diện / cửa) mà ngữ cảnh này muốn được báo. Không có FK (mảng); thiết bị đã xoá thì bị bỏ qua.
--  * homes.active_scene_id: ngữ cảnh chạy gần nhất = "đang bật". Chỉ khi ngữ cảnh đang bật có cảnh báo thì cảm biến mới sinh thông báo.
--  * push_tokens          : token FCM của từng thiết bị của người dùng (Android + iOS đều qua FCM).
--  * notifications        : lịch sử thông báo của căn hộ (giữ 30 ngày).
ALTER TABLE scenes ADD COLUMN alert_devices uuid[] NOT NULL DEFAULT '{}';
ALTER TABLE homes
  ADD COLUMN active_scene_id uuid REFERENCES scenes(id) ON DELETE SET NULL,
  ADD COLUMN active_since    timestamptz;

CREATE TABLE push_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform     text NOT NULL CHECK (platform IN ('ios','android')),
  token        text NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_user_idx ON push_tokens (user_id);

CREATE TABLE notifications (
  id         bigserial PRIMARY KEY,
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  scene_id   uuid REFERENCES scenes(id) ON DELETE SET NULL,
  device_id  uuid REFERENCES devices(id) ON DELETE SET NULL,
  kind       text NOT NULL,
  title      text NOT NULL,
  body       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_home_idx ON notifications (home_id, created_at DESC);
