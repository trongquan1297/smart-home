-- Refresh token xoay vòng (rotation) kèm phát hiện dùng lại (reuse detection).
-- Mỗi lần đăng nhập tạo một "family"; mỗi lần làm mới, token cũ bị đánh dấu used_at và cấp token mới
-- cùng family. Nếu một token đã dùng/đã thu hồi bị trình lại → coi là bị đánh cắp → thu hồi cả family.
-- Chỉ lưu SHA-256 của token (token gốc 256-bit ngẫu nhiên, hiển thị cho client một lần).
CREATE TABLE refresh_tokens (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id         uuid NOT NULL,
  family_started_at timestamptz NOT NULL DEFAULT now(), -- giới hạn tuổi tuyệt đối của phiên
  token_hash        text NOT NULL UNIQUE,
  expires_at        timestamptz NOT NULL,
  used_at           timestamptz,
  revoked_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id);
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (family_id);
CREATE INDEX refresh_tokens_expires_idx ON refresh_tokens (expires_at);
