-- Giãn cách giữa các thiết bị/gang khi chạy ngữ cảnh (tránh bật/tắt mọi đèn cùng một lúc). 0 = gửi cùng lúc như trước.
ALTER TABLE scenes
  ADD COLUMN step_delay_ms integer NOT NULL DEFAULT 0
    CHECK (step_delay_ms BETWEEN 0 AND 10000);
