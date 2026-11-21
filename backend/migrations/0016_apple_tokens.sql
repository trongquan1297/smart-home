-- Refresh token Sign in with Apple (đổi từ authorizationCode lúc đăng nhập) để thu hồi khi người dùng xoá tài khoản,
-- theo yêu cầu App Store. Chỉ dùng được với client của chính app này.
ALTER TABLE user_identities
  ADD COLUMN apple_refresh_token text,
  ADD COLUMN apple_client_id     text;
