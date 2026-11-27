-- Không tự chạy lại khi ngữ cảnh này đang là chế độ đang bật của căn hộ (homes.active_scene_id).
-- Vd "Về nhà" theo cảm biến cửa: chỉ chạy lần mở cửa đầu tiên, mở cửa tiếp không chạy lại cho tới khi ngữ cảnh khác được bật.
ALTER TABLE scenes ADD COLUMN skip_if_active boolean NOT NULL DEFAULT false;
