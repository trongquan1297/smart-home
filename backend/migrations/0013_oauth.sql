-- Máy chủ OAuth 2.0 (authorization code) cho liên kết tài khoản Google Home cloud-to-cloud.
-- Mọi mã/token chỉ lưu dạng băm SHA-256; giá trị thật chỉ trả cho client đúng một lần.
--  * oauth_codes  : mã ủy quyền dùng một lần, sống 10 phút, gắn với người dùng + client + redirect_uri.
--  * oauth_grants : một lần liên kết = một refresh token (không hết hạn, không xoay vòng — theo khuyến nghị
--                   "persistent linking" của Google; thu hồi bằng revoked_at).
--  * oauth_tokens : access token sống 1 giờ, thuộc một grant (thu hồi grant = mọi access token mất hiệu lực).
CREATE TABLE oauth_codes (
  code_hash    text PRIMARY KEY,
  client_id    text NOT NULL,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  redirect_uri text NOT NULL,
  scope        text NOT NULL DEFAULT '',
  expires_at   timestamptz NOT NULL,
  used_at      timestamptz,
  grant_id     uuid
);

CREATE TABLE oauth_grants (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id    text NOT NULL,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scope        text NOT NULL DEFAULT '',
  refresh_hash text NOT NULL UNIQUE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);
CREATE INDEX oauth_grants_user_idx ON oauth_grants (user_id);

CREATE TABLE oauth_tokens (
  token_hash text PRIMARY KEY,
  grant_id   uuid NOT NULL REFERENCES oauth_grants(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL
);
CREATE INDEX oauth_tokens_grant_idx ON oauth_tokens (grant_id);
