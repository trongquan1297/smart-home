-- Camera Wi‑Fi qua addon camera (go2rtc + ONVIF) chạy trong nhà.
--  * cameras.gateway_id : addon đang giữ camera (addon là một gateway khai báo khả năng "camera"). Xoá addon = xoá camera.
--  * KHÔNG lưu mật khẩu/URL camera ở cloud: addon giữ tại chỗ. Cloud chỉ có tên, phòng, địa chỉ hiển thị và khả năng.
--  * motion_alerts : gửi cảnh báo khi camera báo chuyển động (sự kiện ONVIF).
CREATE TABLE cameras (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id       uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  gateway_id    uuid NOT NULL REFERENCES gateways(id) ON DELETE CASCADE,
  room_id       uuid REFERENCES rooms(id) ON DELETE SET NULL,
  name          text NOT NULL,
  host          text NOT NULL,
  manufacturer  text,
  model         text,
  has_ptz       boolean NOT NULL DEFAULT false,
  has_events    boolean NOT NULL DEFAULT false,
  motion_alerts boolean NOT NULL DEFAULT true,
  online        boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX cameras_home_idx ON cameras (home_id);

ALTER TABLE notifications ADD COLUMN camera_id uuid REFERENCES cameras(id) ON DELETE SET NULL;
