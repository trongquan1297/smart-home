-- Đăng nhập bằng Google / Apple: một tài khoản MSmart có thể gắn nhiều danh tính bên ngoài.
-- Tài khoản chỉ đăng nhập bằng Google/Apple có users.password_hash = '' (không đăng nhập bằng mật khẩu được).
CREATE TABLE user_identities (
  provider      text NOT NULL CHECK (provider IN ('google', 'apple')),
  subject       text NOT NULL,           -- claim `sub` của ID token: cố định theo người dùng (email có thể đổi)
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  email         text,                    -- email nhà cung cấp báo lần gần nhất (Apple có thể là địa chỉ chuyển tiếp)
  created_at    timestamptz NOT NULL DEFAULT now(),
  last_login_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, subject)
);
CREATE INDEX user_identities_user ON user_identities (user_id);
