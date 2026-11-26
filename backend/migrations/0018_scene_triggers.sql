-- Điều kiện tự kích hoạt ngữ cảnh, kết hợp HOẶC / VÀ (backend/src/triggers.rs).
--  * trigger_logic   : 'any' = bất kỳ điều kiện nào xảy ra thì chạy; 'all' = khi một điều kiện xảy ra, mọi điều kiện còn lại
--                      phải đang đúng (hẹn giờ → đang trong khung giờ, rời nhà → không còn ai ở nhà, …).
--  * auto_time_end   : giờ kết thúc khung giờ (NULL = chỉ là mốc giờ). Khung qua nửa đêm khi end <= start.
--  * auto_arrive     : chạy khi người đầu tiên về nhà (geofence, như auto_leave).
--  * trigger_sensors : [{"device_id": uuid, "event": "occupied"|"vacant"|"open"|"closed"}].
ALTER TABLE scenes
  ADD COLUMN trigger_logic   text    NOT NULL DEFAULT 'any' CHECK (trigger_logic IN ('any', 'all')),
  ADD COLUMN auto_time_end   time,
  ADD COLUMN auto_arrive     boolean NOT NULL DEFAULT false,
  ADD COLUMN trigger_sensors jsonb   NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(trigger_sensors) = 'array');

-- Có điều kiện VÀ thì nhiều ngữ cảnh "rời nhà" khác nhau là hợp lý (vd rời nhà ban ngày / ban đêm): bỏ giới hạn 1 ngữ cảnh.
DROP INDEX IF EXISTS scenes_one_auto_leave;

CREATE INDEX scenes_trigger_sensors ON scenes USING gin (trigger_sensors jsonb_path_ops);
