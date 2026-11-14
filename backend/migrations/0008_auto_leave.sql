-- Tự chạy ngữ cảnh khi người cuối cùng rời nhà (geofence phía app).
--  * homes.geo_*          : vị trí căn hộ + bán kính (m) do quản trị đặt. App tự đăng ký geofence quanh điểm này;
--                           máy chủ KHÔNG nhận toạ độ của thành viên, chỉ nhận "trong/ngoài".
--  * scenes.auto_leave    : ngữ cảnh chạy khi không còn ai ở nhà (tối đa 1 ngữ cảnh mỗi căn hộ).
--  * member_presence      : trạng thái trong/ngoài gần nhất do điện thoại từng thành viên báo lên.
ALTER TABLE homes
  ADD COLUMN geo_lat      double precision CHECK (geo_lat BETWEEN -90 AND 90),
  ADD COLUMN geo_lng      double precision CHECK (geo_lng BETWEEN -180 AND 180),
  ADD COLUMN geo_radius_m integer NOT NULL DEFAULT 150 CHECK (geo_radius_m BETWEEN 50 AND 2000);
ALTER TABLE scenes ADD COLUMN auto_leave boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX scenes_one_auto_leave ON scenes (home_id) WHERE auto_leave;
CREATE TABLE member_presence (
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  inside     boolean NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (home_id, user_id)
);
