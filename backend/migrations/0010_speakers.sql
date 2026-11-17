-- Thông báo giọng nói qua loa Google Cast (Google Home / Nest Mini...).
--  * speakers      : loa đã thêm vào căn hộ. `cast_id` là id ổn định của thiết bị Cast (TXT "id" trong mDNS), `host`/`port`
--                    chỉ là địa chỉ lần cuối thấy (gateway tự tìm lại theo cast_id nếu IP đổi).
--  * scenes/device_rules.speaker_ids + speak_text : loa nào đọc khi hành động TỰ ĐỘNG này chạy (rỗng = không đọc);
--                    speak_text trống = dùng câu tự sinh.
CREATE TABLE speakers (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  name       text NOT NULL,
  cast_id    text NOT NULL,
  host       text,
  port       integer NOT NULL DEFAULT 8009 CHECK (port BETWEEN 1 AND 65535),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (home_id, cast_id)
);
ALTER TABLE scenes       ADD COLUMN speaker_ids uuid[] NOT NULL DEFAULT '{}', ADD COLUMN speak_text text;
ALTER TABLE device_rules ADD COLUMN speaker_ids uuid[] NOT NULL DEFAULT '{}', ADD COLUMN speak_text text;
