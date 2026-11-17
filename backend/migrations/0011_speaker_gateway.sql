-- Loa thuộc về gateway đã tìm thấy nó (gateway nằm cùng LAN với loa). Một căn hộ có thể có nhiều gateway:
-- gateway Zigbee trên đám mây và gateway chỉ làm loa Cast chạy ở máy trong nhà.
ALTER TABLE speakers ADD COLUMN gateway_id uuid REFERENCES gateways(id) ON DELETE SET NULL;
