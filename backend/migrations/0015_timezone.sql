-- Hiển thị giờ theo Việt Nam (UTC+7) cho mọi phiên mới tới database này (psql, backend...).
-- Chỉ đổi cách HIỂN THỊ: mọi cột thời gian là timestamptz (thời điểm tuyệt đối) nên dữ liệu không đổi; lịch hẹn giờ
-- vẫn tính theo homes.timezone của từng căn hộ.
DO $$
BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Ho_Chi_Minh');
END $$;
