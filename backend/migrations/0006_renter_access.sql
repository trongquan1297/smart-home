-- Khách thuê (role 'renter'): truy cập CÓ THỜI HẠN vào một căn hộ, chỉ được bật/tắt thiết bị.
-- (Không dùng chữ "tenant" vì trong hệ thống đó là khách hàng/chủ tài khoản.)
--   valid_from / valid_until : cửa sổ được phép truy cập (kiểm tra ở MỖI yêu cầu, nên hết hạn/thu hồi có hiệu lực ngay)
--   duration_hours           : thời lượng gốc, dùng khi "cấp quyền ngay" khởi động lại cửa sổ
-- Thu hồi ngay = xoá dòng home_members. Lịch sử không lưu ở đây; hành động của khách vẫn nằm trong command_log.
ALTER TABLE home_members DROP CONSTRAINT home_members_role_check;
ALTER TABLE home_members ADD CONSTRAINT home_members_role_check CHECK (role IN ('owner','admin','member','renter','guest'));
ALTER TABLE home_members
  ADD COLUMN valid_from     timestamptz,
  ADD COLUMN valid_until    timestamptz,
  ADD COLUMN duration_hours integer;
ALTER TABLE home_members ADD CONSTRAINT home_members_renter_window CHECK (
  (role = 'renter') = (valid_from IS NOT NULL AND valid_until IS NOT NULL AND duration_hours IS NOT NULL)
);

-- Lời mời khách thuê mang thời lượng (giờ) và giờ bắt đầu tuỳ chọn; cửa sổ thật chỉ tính khi khách chấp nhận lời mời.
ALTER TABLE home_invites DROP CONSTRAINT home_invites_role_check;
ALTER TABLE home_invites ADD CONSTRAINT home_invites_role_check CHECK (role IN ('admin','member','renter','guest'));
ALTER TABLE home_invites
  ADD COLUMN duration_hours integer,
  ADD COLUMN starts_at      timestamptz;
ALTER TABLE home_invites ADD CONSTRAINT home_invites_renter_duration CHECK ((role = 'renter') = (duration_hours IS NOT NULL));
