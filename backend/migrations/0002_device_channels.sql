-- description: mô tả model do Zigbee2MQTT báo (vd "Wall switch 3 gang") → loại nhận dạng của thiết bị.
-- channels: tên + loại tải do người dùng đặt cho từng gang/kênh,
--   {"state_1":{"name":"Đèn trần","type":"light"}, "state_2":{"name":"Quạt","type":"fan"}}
ALTER TABLE devices
  ADD COLUMN description text,
  ADD COLUMN channels jsonb NOT NULL DEFAULT '{}';
