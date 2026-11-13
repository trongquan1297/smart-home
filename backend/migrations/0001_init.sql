-- Mô hình đa khách hàng (multi-tenant):
--   tenant (khách hàng) 1─n home (căn hộ) 1─n room (phòng) 1─n device
--   user n─n home qua home_members (vai trò trong căn hộ)
--   user n─n tenant qua tenant_members (quản trị khách hàng)
--   gateway = 1 Raspberry Pi (Zigbee2MQTT) gắn với 1 home
-- Mọi bảng dữ liệu đều mang tenant_id/home_id để kiểm soát cô lập ở tầng truy vấn.

CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text NOT NULL,
  password_hash text NOT NULL,
  name          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_lower_uq ON users (lower(email));

CREATE TABLE tenants (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tenant_members (
  tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('owner','admin')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, user_id)
);
CREATE INDEX tenant_members_user_idx ON tenant_members (user_id);

CREATE TABLE homes (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  name       text NOT NULL,
  address    text,
  timezone   text NOT NULL DEFAULT 'Asia/Ho_Chi_Minh',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX homes_tenant_idx ON homes (tenant_id);

CREATE TABLE home_members (
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('owner','admin','member','guest')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (home_id, user_id)
);
CREATE INDEX home_members_user_idx ON home_members (user_id);

-- Mời thành viên gia đình: token chỉ hiển thị 1 lần, lưu dạng hash.
CREATE TABLE home_invites (
  token_hash text PRIMARY KEY,
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('admin','member','guest')),
  created_by uuid NOT NULL REFERENCES users(id),
  expires_at timestamptz NOT NULL,
  used_at    timestamptz
);

CREATE TABLE gateways (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  home_id      uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  name         text NOT NULL,
  token_hash   text NOT NULL UNIQUE,
  last_seen_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX gateways_home_idx ON gateways (home_id);

CREATE TABLE rooms (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  name       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (home_id, name)
);

CREATE TABLE devices (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
  home_id       uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  gateway_id    uuid NOT NULL REFERENCES gateways(id) ON DELETE CASCADE,
  room_id       uuid REFERENCES rooms(id) ON DELETE SET NULL,
  ieee_address  text NOT NULL,
  friendly_name text NOT NULL,          -- tên trong Zigbee2MQTT (dùng làm MQTT topic)
  name          text NOT NULL,          -- tên hiển thị do người dùng đặt
  vendor        text,
  model         text,
  kind          text NOT NULL DEFAULT 'other', -- switch | light | other
  exposes       jsonb NOT NULL DEFAULT '[]',
  state         jsonb NOT NULL DEFAULT '{}',
  online        boolean NOT NULL DEFAULT false,
  last_seen_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (gateway_id, ieee_address)
);
CREATE INDEX devices_home_idx ON devices (home_id);
CREATE INDEX devices_gw_name_idx ON devices (gateway_id, friendly_name);

-- Nhật ký lệnh (audit): ai bật/tắt gì, lúc nào.
CREATE TABLE command_log (
  id         bigserial PRIMARY KEY,
  device_id  uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  home_id    uuid NOT NULL REFERENCES homes(id) ON DELETE CASCADE,
  user_id    uuid REFERENCES users(id) ON DELETE SET NULL,
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX command_log_home_idx ON command_log (home_id, created_at DESC);
