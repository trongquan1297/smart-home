# Smart Home — Zigbee2MQTT + Rust + Flutter

Giải pháp nhà thông minh đa khách hàng (multi-tenant): app Flutter → backend Rust/Postgres (cloud) → gateway trên Raspberry Pi 3 → Zigbee2MQTT → công tắc Zigbee.

```
 Flutter app ──HTTPS/WSS──▶ Backend (Rust, Postgres) ◀──WSS (outbound)── gateway agent ── MQTT ── Zigbee2MQTT ── USB dongle ── công tắc
   (điện thoại)             (Cloudflare / VPS)                           └────────── Raspberry Pi 3 tại nhà ──────────┘
```

| Thư mục | Nội dung |
|---|---|
| `backend/` | API Rust (axum + sqlx + Postgres): auth, tenant/căn hộ/phòng/thiết bị/thành viên, WebSocket realtime |
| `gateway/` | Agent Rust chạy trên Pi: cầu nối MQTT cục bộ ⇄ WebSocket lên cloud |
| `app/` | App Flutter (Android/iOS) |
| `infra/` | Cấu hình Mosquitto, Zigbee2MQTT, **bộ giả lập Zigbee2MQTT có frontend web** |
| `edge/` | `docker-compose` triển khai thật trên Pi |
| `scripts/` | `bootstrap-dev.sh` tạo dữ liệu mẫu |
| `docs/ARCHITECTURE.md` | Thiết kế, bảo mật, triển khai Cloudflare, việc còn lại |

## Chạy giả lập (không cần dongle)

```bash
export COMPOSE_PROFILES=sim
docker compose up -d --build postgres backend mosquitto zigbee-sim   # 1) cloud + MQTT + thiết bị giả
./scripts/bootstrap-dev.sh                                           # 2) tạo user/tenant/căn hộ/phòng + ghi GATEWAY_TOKEN vào .env
docker compose up -d --build gateway                                 # 3) gateway nối MQTT ⇄ backend
```

Simulator giả lập đúng các model VSmart: công tắc 1/2/3 gang, cảm biến cửa, cảm biến hiện diện (cảm biến tự đổi trạng thái mỗi 20 giây để thử realtime). Tài khoản mẫu: `owner@example.com` / `change-me-123`.

### Frontend Zigbee2MQTT giả lập (thay cho Pi)

Mở **http://localhost:8081**. Đây là bộ giả lập, không phải giao diện Zigbee2MQTT thật, nhưng phát/nhận đúng các topic MQTT nên backend và app chạy y như khi có Pi:

1. Bấm **Bật permit join** (tự tắt sau 120 giây).
2. Chọn model (VSmart công tắc 1–4 gang, cảm biến cửa, cảm biến hiện diện) → **Ghép**.
3. Sau ~2 giây thiết bị xuất hiện, tên mặc định là địa chỉ IEEE (giống Z2M thật) → vào app, thiết bị nằm ở "Chưa phân phòng" → gán phòng.
4. Có thể **Đổi tên**, **Xoá**, bật/tắt từng gang, hoặc **Kích hoạt cảm biến** để thử realtime trên app.

Tên hiển thị trong app đi theo tên Z2M cho tới khi bạn tự đổi tên trong app; sau đó tên trong app được giữ nguyên.

Chạy app:

```bash
cd app && flutter pub get
flutter run --dart-define=API_URL=http://localhost:8080      # iOS simulator
flutter run --dart-define=API_URL=http://10.0.2.2:8080       # Android emulator
```

Thử nhanh bằng curl:

```bash
TOKEN=$(curl -s localhost:8080/v1/auth/login -H 'content-type: application/json' \
  -d '{"email":"owner@example.com","password":"change-me-123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s localhost:8080/v1/homes -H "authorization: Bearer $TOKEN"
```

## Ngữ cảnh và tự kích hoạt theo khung giờ

Trong app: căn hộ → biểu tượng ✨ **Ngữ cảnh**. Một ngữ cảnh là nhóm thao tác Bật/Tắt theo từng gang của nhiều công tắc (vd "Đi ngủ" tắt hết đèn); bấm ▶ để chạy ngay, hoặc bật **Tự động kích hoạt** để chọn giờ và các ngày trong tuần. Giờ tính theo múi giờ của căn hộ (`homes.timezone`, mặc định Asia/Ho_Chi_Minh).

- Backend chạy vòng lặp nền 20 giây/lần; mỗi lần đến giờ được "giành" bằng một câu UPDATE có điều kiện nên không chạy đôi.
- Bộ điều khiển trung tâm (Pi) offline lúc đến giờ: thử lại trong 5 phút; quá hạn thì ghi **bỏ lỡ** (hiện trên thẻ ngữ cảnh), **không chạy bù muộn**. Backend tắt đúng lúc đến giờ cũng bị coi là bỏ lỡ.
- Chỉ nhận `ON`/`OFF` (không `TOGGLE`, để chạy lại cho cùng kết quả); payload đi qua đúng whitelist của lệnh điều khiển; lệnh tự động ghi `command_log` với `user_id` rỗng.
- Giới hạn: 50 ngữ cảnh/căn hộ, 50 hành động/ngữ cảnh. Đây là lịch theo giờ cố định; chưa có kích hoạt theo mặt trời mọc/lặn, theo cảm biến hay theo vị trí.

## Chạy với Zigbee2MQTT thật trên Pi 3

1. Cắm dongle, tìm đường dẫn ổn định: `ls /dev/serial/by-id/`.
2. Sonoff ZBDongle-E đã cấu hình `adapter: ember`; cần firmware **coordinator** EmberZNet ≥ 7.4.x (xem ghi chú trong `infra/zigbee2mqtt/configuration.yaml`). Đặt `network_key`/`pan_id`/`ext_pan_id` ngẫu nhiên.
3. Trên Pi: `cd edge && cp .env.example .env` → điền `CLOUD_WS_URL` (dạng `wss://api.<domain>/gw/ws`), `GATEWAY_TOKEN`, `ZIGBEE_DEVICE` → `./gen-secrets.sh` (sinh mật khẩu MQTT ngẫu nhiên vào `.env`; Mosquitto không cho kết nối ẩn danh) → `docker compose up -d`.
4. Ghép thiết bị: mở Z2M frontend `http://<ip-pi>:8081`, bật *Permit join*, reset công tắc theo hướng dẫn của hãng. Thiết bị tự đồng bộ lên app.

`GATEWAY_TOKEN` lấy trong app: vào căn hộ → biểu tượng router (**Bộ điều khiển trung tâm**) → **Thêm** → app hiện `CLOUD_WS_URL` và `GATEWAY_TOKEN` (chỉ hiện một lần; chỉ admin/owner). Hoặc gọi `POST /v1/homes/:home_id/gateways`; script bootstrap làm sẵn cho dev.

## Kết nối Google Home / Apple Home (Matter)

App có thể tạo mã QR để ghép toàn bộ thiết bị với **Google Home / Apple Home** (và Alexa, SmartThings) qua chuẩn **Matter**.

```
Home app (điện thoại)  ──LAN/mDNS──▶  Matterbridge (Pi, host network)  ◀──MQTT──  Zigbee2MQTT
                                            ▲ WebSocket cục bộ
Flutter app ── backend (cloud) ◀── gateway agent ┘   (lấy mã QR, mở/đóng ghép nối, ngắt ứng dụng)
```

- Matter điều khiển **trong mạng LAN nhà**, nên bridge chạy trên Pi (`infra/matterbridge`, dựa trên [Matterbridge](https://github.com/Luligu/matterbridge) + plugin `matterbridge-zigbee2mqtt`), không chạy trên cloud.
- Trong app: vào căn hộ → biểu tượng **QR** (chỉ admin/owner) → quét mã bằng Home app (Apple Home: *+ → Thêm phụ kiện*; Google Home: *+ → Thiết lập thiết bị → thiết bị tương thích Matter*).
- Sau khi đã ghép, mã ẩn đi; bấm **Thêm ứng dụng khác** để mở lại chế độ ghép nối (ví dụ thêm Google Home sau Apple Home). Danh sách ứng dụng đã ghép có nút **Ngắt kết nối**.
- Thiết bị hiện trong Home app: công tắc dưới dạng **đèn** (mỗi gang một đèn; đổi sang `outlet`/`switch` bằng `MATTER_SWITCH_AS`), cảm biến cửa, cảm biến hiện diện. Thiết bị ghép mới vào Zigbee2MQTT cần `docker compose restart matterbridge` trên Pi mới xuất hiện trong Home app.
- Bật trên Pi: `edge/docker-compose.yml` đã có service `matterbridge` (`network_mode: host`, **bắt buộc** cho mDNS). Pi và điện thoại phải cùng mạng khi ghép.
- Dev: `COMPOSE_PROFILES=sim,matter docker compose up -d --build` dựng bridge trong mạng compose để kiểm tra mã QR và luồng trong app. **Không ghép được với Home app thật** vì mDNS không ra LAN (nhất là Docker Desktop).
- Bảo mật: mã QR/mã số cho phép thêm người điều khiển ngôi nhà. Backend không lưu mã (chỉ chuyển tiếp qua WebSocket khi admin mở màn hình, `Cache-Control: no-store`), gateway chỉ trả mã khi bridge đang cho phép ghép nối. Frontend Matterbridge (cổng 8283) **mặc định không có mật khẩu**: để `MB_BIND=127.0.0.1` và đừng mở ra LAN; nếu đặt mật khẩu trong frontend thì đặt `MATTERBRIDGE_PASSWORD` cho gateway.
- **Sao lưu volume `matterbridge-data`**: chứa thông tin ghép nối. Mất volume thì phải ghép lại với mọi Home app.

## Mô hình dữ liệu & phân quyền

- **Tenant** (khách hàng) → nhiều **Home** (căn hộ) → nhiều **Room** và **Device**; mỗi home có gateway (Pi) riêng.
- Vai trò trong căn hộ: `owner` > `admin` (quản lý phòng/thiết bị/thành viên/gateway) > `member` (điều khiển) > `guest` (chỉ xem).
- Owner/admin của tenant mặc nhiên là `admin` mọi căn hộ trong tenant. Người ngoài căn hộ nhận `404` (không lộ sự tồn tại).
- Mời người nhà bằng mã mời 1 lần, hạn 7 ngày (`POST /v1/homes/:id/invites` → người nhận `POST /v1/invites/accept`).

## API chính

| | |
|---|---|
| `POST /v1/auth/register`, `/v1/auth/login`, `GET /v1/me` | tài khoản; đăng ký/đăng nhập trả `token` (access, 15 phút) + `refresh_token` |
| `GET/POST /v1/homes/:id/scenes`, `PATCH/DELETE /v1/scenes/:id`, `POST /v1/scenes/:id/run` | ngữ cảnh (scene): xem = guest, chạy = member, tạo/sửa/xoá = admin. Body: `name`, `icon`, `actions:[{device_id,payload}]`, tuỳ chọn tự kích hoạt `auto_enabled`, `auto_time` ("HH:MM"), `auto_days` (1 = T2 … 7 = CN) |
| `POST /v1/auth/refresh`, `/v1/auth/logout`, `/v1/auth/logout-all` | làm mới (xoay vòng), đăng xuất thiết bị, đăng xuất mọi thiết bị; đăng nhập/đăng ký/làm mới có giới hạn tốc độ (`429` + `Retry-After`) |
| `POST /v1/tenants`, `POST /v1/tenants/:tid/homes`, `GET /v1/homes` | khách hàng, căn hộ |
| `GET/POST /v1/homes/:id/rooms`, `PATCH/DELETE /v1/rooms/:id` | phòng: tên + icon (`living` `bedroom` `kitchen` `bathroom` `dining` `office` `balcony` `garage` `kids` `laundry` `hallway` `other`) |
| `GET /v1/homes/:id/devices`, `PATCH /v1/devices/:id` | thiết bị: đổi tên, gán phòng, đặt tên + loại tải cho từng gang (`channels`: `light` `fan` `outlet` `air_conditioner` `water_heater` `other`) |
| `POST /v1/devices/:id/command` `{"payload":{"state_1":"TOGGLE"}}` | điều khiển → `202`; `503` nếu gateway offline |
| `GET /v1/homes/:id/ws?token=` | realtime: `device_state`, `device_online`, `gateway`, `devices_changed` |
| `GET/POST /v1/homes/:id/members…`, `/invites`, `/gateways` | thành viên, mời, gateway |
| `GET /v1/homes/:id/matter`, `POST …/matter/pairing` `{"open":bool}`, `DELETE …/matter/fabrics/:index` | Matter: trạng thái + mã QR (admin), mở/đóng ghép nối, ngắt một ứng dụng |
| `POST /v1/gateways/:id/rotate`, `DELETE /v1/gateways/:id` | thu hồi token gateway (giữ thiết bị) / xoá gateway (xoá cả thiết bị của nó) |

Lệnh chỉ chấp nhận thuộc tính `state*` (ON/OFF/TOGGLE), `brightness*`, `color_temp*`; mọi payload khác bị từ chối để client không thể gọi các topic quản trị của Zigbee2MQTT.

## Đã kiểm chứng / chưa kiểm chứng

Đã chạy thật trong Docker: build 3 image, migration, đồng bộ thiết bị từ simulator, bật/tắt qua Pi (gateway→MQTT→simulator→trạng thái về), 400 với payload sai, 404 với người ngoài, 403 khi guest điều khiển, mã mời dùng 1 lần, WebSocket realtime, 503 khi gateway offline. App Flutter: `flutter analyze` sạch, đã chạy trên iOS Simulator (đăng nhập, xem căn hộ, đăng xuất; chưa thử Android và thiết bị thật). Bảo mật: Mosquitto bắt buộc đăng nhập + ACL, giới hạn đăng nhập/đăng ký, refresh token xoay vòng (kiểm thử API và WebSocket hết hạn, xem `docs/ARCHITECTURE.md` §5). Thuộc tính thiết bị đã đối chiếu với tài liệu Zigbee2MQTT nhưng chưa thử với dongle và thiết bị VSmart thật, chưa deploy lên Cloudflare, test tự động mới có ở mức đơn vị (`cd backend && cargo test`, `cd app && flutter test --dart-define=API_URL=http://127.0.0.1:18080 test/api_refresh_test.dart`) — xem `docs/ARCHITECTURE.md` mục "Việc còn lại".
