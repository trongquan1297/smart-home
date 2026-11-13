# Kiến trúc

## 1. Vì sao có "gateway agent" thay vì app/backend nói MQTT trực tiếp với Pi

Pi nằm sau NAT của nhà dân, không có IP public. Hai lựa chọn: (a) mở port/VPN vào từng nhà — khó vận hành và rủi ro bảo mật cho nhiều khách hàng; (b) Pi **chủ động kết nối ra** cloud. Giải pháp chọn (b): agent Rust nhỏ trên Pi giữ 1 WebSocket TLS tới backend, xác thực bằng token riêng của từng gateway.

Hệ quả: Pi không cần mở port; Mosquitto chỉ nằm trong mạng nội bộ; mất Internet thì Zigbee/Z2M vẫn chạy cục bộ, khi có mạng lại agent phát lại toàn bộ trạng thái (cache) lên cloud.

## 2. Luồng dữ liệu

- **Đồng bộ thiết bị**: Z2M publish `zigbee2mqtt/bridge/devices` (retained) → agent → `{"type":"devices"}` → backend upsert vào `devices`, suy ra `kind` và lưu `exposes`. Thiết bị bị gỡ khỏi Z2M thì bị xoá khỏi DB. Phòng do người dùng gán không bị ghi đè; tên hiển thị đi theo tên Z2M cho tới khi người dùng tự đặt tên trong app.
- **Trạng thái**: `zigbee2mqtt/<name>` → `{"type":"state"}` → `devices.state = state || payload` (jsonb merge) → broadcast cho app của home đó.
- **Điều khiển**: app `POST /v1/devices/:id/command` → kiểm quyền (≥ member) + validate payload → gửi `{"type":"set"}` xuống đúng gateway → agent publish `zigbee2mqtt/<name>/set`. Backend **không lạc quan hoá** trạng thái; UI cập nhật khi thiết bị báo lại qua WebSocket. Mỗi lệnh ghi vào `command_log` (ai, lúc nào).
- **Availability**: `zigbee2mqtt/<name>/availability` → cờ `online`.

Loại nhận dạng của thiết bị lấy từ mô tả model Z2M (`devices.description`, vd "Wall switch 3 gang"). Người dùng đặt tên + loại tải cho từng gang trong `devices.channels` (đèn, quạt, ổ cắm, điều hòa, bình nóng lạnh, khác). Tên/loại gang gắn với thiết bị nên một gang không thể thuộc phòng khác với thiết bị.

Phòng có `icon` do người dùng chọn (`rooms.icon`); khi chưa chọn, app tự gợi ý theo tên phòng (so khớp từ nguyên vẹn, bỏ dấu tiếng Việt: "bếp" → bếp, "vệ sinh"/"tắm" → vệ sinh...).

Công tắc nhiều gang: Z2M đặt tên thuộc tính theo endpoint (VSmart: `state_1`, `state_2`...). App đọc cây `exposes` để dựng đúng số công tắc, nên không cần code riêng cho từng model.

## 3. Multi-tenant

Cô lập ở tầng ứng dụng: mọi truy vấn đi qua `access::require(user, home, min_role)`; mọi bảng dữ liệu có `home_id` (và `tenant_id` với bảng thiết bị/gateway). Không có endpoint nào nhận `tenant_id` từ client ngoại trừ tạo căn hộ (có kiểm tra thành viên tenant). Tăng cường nên làm: Postgres Row-Level Security với `SET LOCAL app.user_id` trên mỗi transaction để DB là lớp phòng thủ thứ hai.

## 4. Triển khai trên Cloudflare

> Các nhận định về sản phẩm Cloudflare dưới đây dựa trên hiểu biết chung, **chưa được đối chiếu với tài liệu hiện hành** (tính năng, giới hạn, giá thay đổi). Kiểm tra lại trên developers.cloudflare.com trước khi chốt.

Ràng buộc kỹ thuật cần cân nhắc: backend là tiến trình Rust dài hạn (tokio) giữ WebSocket cho cả gateway và app, và nói chuyện với Postgres bằng `sqlx`. Cloudflare Workers chạy Rust qua WASM (`workers-rs`) nhưng không chạy được tokio/sqlx như hiện tại, nên chuyển thẳng sang Workers đồng nghĩa viết lại tầng I/O.

| Phương án | Mô tả | Đánh giá |
|---|---|---|
| **A. (khuyến nghị cho MVP)** Container backend ở bất kỳ nơi chạy container (VPS, Fly.io, ...) + **Cloudflare Tunnel** | `cloudflared` (đã có profile `tunnel` trong compose) đưa traffic Cloudflare → backend; không mở port. DNS/TLS/WAF/DDoS ở Cloudflare. Postgres managed (Neon, Supabase, RDS...) hoặc tự host. WebSocket đi qua proxy Cloudflare. | Chạy được ngay với code hiện tại. |
| **B.** Backend trong **Cloudflare Containers**, Worker phía trước, Postgres qua **Hyperdrive** | Giữ nguyên code Rust, mọi thứ trong hệ sinh thái Cloudflare. | Cần kiểm tra trạng thái GA/giới hạn của Containers, hỗ trợ WebSocket dài hạn, giá. |
| **C.** Viết lại bằng Workers + **Durable Objects** (mỗi home = 1 DO làm hub realtime) | Scale ngang tự nhiên, hub không còn là bộ nhớ cục bộ. | Viết lại nhiều; chỉ nên làm khi có nhu cầu quy mô lớn. |

Gateway trên Pi dùng `CLOUD_WS_URL=wss://api.<domain>/gw/ws` → đi qua Cloudflare. Gửi ping 30 giây để tránh bị đóng do idle.

**Scale-out**: `Hub` hiện nằm trong RAM một tiến trình. Chạy ≥2 instance backend thì gateway và app của cùng một home có thể rơi vào instance khác nhau → cần pub/sub chung (Postgres `LISTEN/NOTIFY` là cách ít thành phần nhất; hoặc Redis/DO). Với 1 instance hoặc sticky routing theo home thì không cần.

## 4b. Ngữ cảnh và tự kích hoạt

Bảng `scenes` (migration 0005): `actions` jsonb `[{device_id, payload}]` (không có FK tới `devices`: thiết bị bị xoá thì hành động đó bị bỏ qua khi chạy), cộng cột tự kích hoạt `auto_enabled/auto_time/auto_days` và `last_run_at/last_status`. Bộ chạy (`backend/src/automation.rs`) là một task nền trong tiến trình backend, **không** nằm trên Pi, nên cần backend và gateway cùng online lúc đến giờ.

- Tính giờ: `due_instant` đổi giờ địa phương của căn hộ sang UTC (xét cả "hôm nay" và "hôm qua" để không lọt lịch vắt qua nửa đêm; giờ không tồn tại do nhảy giờ mùa hè thì bỏ qua; múi giờ sai thì dùng Asia/Ho_Chi_Minh).
- Chống chạy đôi: `UPDATE … WHERE last_run_at < <thời điểm định>` trả về đúng 1 dòng mới được chạy, nên an toàn khi có nhiều bản backend. Tạo/sửa giờ đặt `last_run_at = now()` để không chạy bù lần đã qua trong ngày.
- Gateway offline: thử lại ở các tick sau trong 5 phút (`GRACE_SECS`), quá hạn ghi `missed`. Chọn bỏ lỡ thay vì chạy bù vì bật/tắt thiết bị trễ nhiều giờ có thể gây hại hơn là bỏ qua.
- Giới hạn đã biết: độ chính xác ±20 giây (chu kỳ tick); lệnh chỉ "đã gửi xuống gateway", chưa chờ thiết bị xác nhận nên `ok` nghĩa là đã gửi đủ lệnh chứ không đảm bảo thiết bị đã đổi trạng thái; ngữ cảnh chạy bằng tay và lệnh điều khiển thường dùng chung bảng `command_log`.

## 5. Bảo mật — đã làm / còn thiếu

Đã có: mật khẩu argon2 (tối đa 4 lần băm đồng thời để không bị bóp RAM/CPU); gateway/invite token 256-bit chỉ lưu hash SHA-256, hiển thị 1 lần; mã mời dùng 1 lần có hạn; whitelist payload lệnh; agent từ chối tên thiết bị chứa `/ # +` (chống topic injection); container chạy non-root; người ngoài nhận 404; và ba mục dưới đây.

### Mosquitto: bắt buộc đăng nhập + ACL

`allow_anonymous false`, mỗi dịch vụ một tài khoản riêng (`infra/mosquitto/acl.conf`):

| Tài khoản | Quyền |
|---|---|
| `z2m` (Zigbee2MQTT thật hoặc simulator) | đọc/ghi `zigbee2mqtt/#` |
| `gateway` | đọc `zigbee2mqtt/#`; chỉ ghi `zigbee2mqtt/+/set` (không giả mạo trạng thái, không gọi `bridge/request/*` như `permit_join`) |
| `matterbridge` | đọc/ghi `zigbee2mqtt/#` (xem lưu ý dưới) |

File mật khẩu do `infra/mosquitto/entrypoint.sh` tạo mỗi lần khởi động từ biến `MQTT_PASSWORD_Z2M/_GATEWAY/_MATTERBRIDGE` (thiếu hoặc <16 ký tự thì broker từ chối chạy), nên repo không chứa mật khẩu nào. Trên Pi: `cd edge && ./gen-secrets.sh` sinh mật khẩu ngẫu nhiên 256-bit vào `edge/.env` (chmod 600, không ghi đè mật khẩu đã có). Compose dev dùng mật khẩu `dev-only-*` vì cổng chỉ mở ở `127.0.0.1`.

Đã kiểm chứng trong dev: ẩn danh và sai mật khẩu bị từ chối; `gateway` không đọc được `$SYS`, publish được `…/set` nhưng `…/bridge/request/permit_join`, topic ngoài cây và ghi đè trạng thái thiết bị đều bị chặn; simulator, gateway và Matterbridge kết nối bình thường. **Chưa kiểm chứng**: Zigbee2MQTT thật đọc `ZIGBEE2MQTT_CONFIG_MQTT_USER/PASSWORD` (tên biến suy ra từ quy tắc trong tài liệu Z2M, tài liệu không liệt kê riêng hai biến này; nếu Z2M báo lỗi đăng nhập thì chuyển sang `secret.yaml`); và plugin Matterbridge cần ghi những topic nào khi Home app điều khiển (nên cấp rộng `zigbee2mqtt/#`, thu hẹp thì phải thử lại).

### Giới hạn tốc độ

Cửa sổ trượt 15 phút trong RAM (`backend/src/ratelimit.rs`):

- Đăng nhập: khoá theo **IP** sau 20 lần sai và theo **tài khoản** sau 10 lần sai; trả `429` + `Retry-After`. Kiểm tra trước khi băm mật khẩu nên bị khoá thì không tốn CPU, và đúng mật khẩu lúc đang khoá cũng chưa vào được. Đăng nhập đúng xoá bộ đếm của tài khoản (không xoá của IP).
- Đăng ký: 10 lần/giờ/IP (tính cả lần lỗi). Làm mới token: 30 lần sai/15 phút/IP.
- Email không tồn tại vẫn băm một lần (băm giả) để thời gian phản hồi không lộ email nào có tài khoản (đo trong dev: ~15 ms so với ~13 ms).
- IPv6 gộp theo /64. Tối đa 100 000 khoá trong RAM.

Đánh đổi cần biết: khoá theo tài khoản cho phép kẻ khác **chủ ý khoá đăng nhập mới** của một email trong 15 phút (đăng nhập bằng phiên đang có, tức refresh token, vẫn chạy). Giới hạn là **theo tiến trình**: chạy nhiều bản backend thì ngưỡng thực tế nhân lên, khi đó chuyển sang Redis/Postgres hoặc thêm rule Cloudflare Rate Limiting.

**IP thật của client**: mặc định lấy địa chỉ kết nối TCP. Khi backend CHỈ truy cập được qua Cloudflare Tunnel (không publish cổng 8080), đặt `TRUSTED_IP_HEADER=CF-Connecting-IP`; nếu không, mọi client chung một IP (của cloudflared) và một người sai 20 lần sẽ khoá tất cả. Tuyệt đối không đặt biến này khi backend lộ trực tiếp ra Internet: client giả mạo được header để né giới hạn. Trong dev (Docker Desktop) mọi yêu cầu từ máy host thấy chung một IP của lớp NAT, nên thử nghiệm khoá IP sẽ khoá cả đăng nhập của app trên cùng máy trong 15 phút (khởi động lại backend để xoá).

### Phiên đăng nhập: access token ngắn + refresh token xoay vòng

- Access token (JWT HS256): **15 phút**. WebSocket của app bị server đóng đúng lúc access token hết hạn (đo: 12,0 s với token 12 s), app làm mới token rồi nối lại.
- Refresh token: ngẫu nhiên 256-bit, chỉ lưu SHA-256 (bảng `refresh_tokens`). Sống 30 ngày mỗi lần cấp, tổng phiên tối đa 90 ngày. Mỗi lần làm mới (`POST /v1/auth/refresh`) token cũ chỉ dùng được **một lần**; trình lại token đã dùng hoặc đã thu hồi → thu hồi cả phiên (nghi bị đánh cắp) và ghi log cảnh báo.
- `POST /v1/auth/logout` thu hồi phiên của thiết bị; `POST /v1/auth/logout-all` thu hồi mọi thiết bị. Access token đang sống vẫn dùng được tới khi hết hạn (tối đa 15 phút).
- App gộp các lần làm mới đồng thời thành một (gọi song song sẽ bị coi là dùng lại). Chỉ coi là hết phiên khi server trả 401; mất mạng hoặc lỗi server thì giữ phiên.
- Hạn chế đã biết: nếu server đã xoay vòng mà phản hồi bị mất giữa đường, app thử lại bằng token cũ và bị coi là dùng lại → phải đăng nhập lại.
- Phiên cũ (JWT 7 ngày, không có refresh token) không còn dùng được: người dùng đăng nhập lại một lần.

Còn thiếu (cần làm trước khi cho khách hàng thật dùng):
1. **WebSocket app** nhận access token qua query `?token=` (có thể lọt vào log của proxy). Đổi sang ticket một lần ngắn hạn hoặc header. (Giảm nhẹ: token chỉ sống 15 phút.)
2. Xác minh email, quên mật khẩu, đổi mật khẩu (đổi mật khẩu nên gọi `revoke_all`). (Đã có: thu hồi/xoay token gateway và xoá gateway, xem dưới.)
3. **Postgres RLS**, sao lưu (PITR), quản lý secret (`JWT_SECRET` và `POSTGRES_PASSWORD` trong compose dev có giá trị mặc định, phải thay khi triển khai).
4. Z2M: đổi `network_key`/`pan_id`; frontend Z2M (`:8081`) không có xác thực và đang publish ra LAN của Pi, cần `frontend.auth_token` hoặc bind loopback; không để ra Internet.
5. Matterbridge: frontend không có mật khẩu mặc định (đang bind `127.0.0.1`).

### Thu hồi token gateway

- `POST /v1/gateways/:id/rotate`: sinh token mới, token cũ vô hiệu ngay, kết nối WebSocket đang mở bị ngắt; thiết bị/phòng/tên giữ nguyên. Dùng khi nghi lộ token.
- `DELETE /v1/gateways/:id`: xoá gateway **và các thiết bị của nó** (cascade), ngắt kết nối. Cần quyền admin/owner của căn hộ.
- Có kiểm tra lại token sau khi đăng ký kết nối để loại bỏ race giữa lúc xác thực và lúc thu hồi. Ghi log cảnh báo kèm user thực hiện.
- Giới hạn: hub nằm trong RAM một tiến trình; khi chạy nhiều instance, lệnh ngắt kết nối chỉ có hiệu lực trên instance đang giữ kết nối (token cũ vẫn bị từ chối ở lần kết nối kế tiếp trên mọi instance).

## 6. Thiết bị VSmart và dongle (đã đối chiếu tài liệu Zigbee2MQTT)

Nguồn: zigbee2mqtt.io/supported-devices (filter VSmart) và từng trang `/devices/<model>.html`, đọc ngày 2026-11-13. Tài liệu có thể thay đổi.

| Model | Loại | Thuộc tính | Ghép nối (theo tài liệu) |
|---|---|---|---|
| HS-SW100ZB-VNM | Công tắc 1 gang | `state` | giữ nút 5 giây tới khi LED nháy nhanh |
| HS-SW200ZB-VNM | Công tắc 2 gang | `state_1`, `state_2` | như trên |
| HS-SW300ZB-VNM | Công tắc 3 gang | `state_1`..`state_3` | như trên |
| HS-SW400ZB-VNM | Công tắc 4 gang (không thuộc danh sách bạn nêu, có trong tài liệu) | `state_1`..`state_4` | như trên |
| HS-SEDR00ZB-VNM | Cảm biến cửa | `contact`, `battery_low`, `tamper` | giữ nút 3 giây |
| HS-SEOC00ZB-VNM | Cảm biến hiện diện | `occupancy`, `battery` | giữ nút 3 giây |

Reset tất cả: giữ nút 10 giây tới khi LED nháy 3 lần. Công tắc có thêm các tuỳ chọn (màu LED, rung, cường độ LED theo buổi...) chưa được đưa vào app.

Lưu ý: công tắc 1 gang dùng `state`, còn 2 gang trở lên dùng `state_1`... (không phải `state_l1` như ban đầu giả định; sửa ở simulator và app). Quy ước `contact=true` là đóng, `occupancy=true` là có người là quy ước chung của Z2M; **cần xác nhận trên thiết bị thật** vì trang thiết bị chỉ ghi giá trị ON/OFF của binary.

**Sonoff ZBDongle-E**: `adapter: ember`, không đặt `rtscts: true`; firmware coordinator EmberZNet 7.4.x trở lên (không dùng firmware router). Baudrate tài liệu không nêu riêng cho dongle này, nên dùng mặc định; chỉnh nếu kết nối lỗi. Nguồn: guide/adapters/emberznet.html, devices/ZBDongle-E.html.

Cảm biến chạy pin báo trạng thái theo sự kiện nên `online` có thể trễ hơn công tắc; chưa kiểm tra thực tế.

## 6b. Matter bridge (Google Home / Apple Home)

**Vì sao nằm trên Pi**: Matter chạy trên LAN (mDNS + UDP/IPv6), controller phải thấy bridge trực tiếp. Cloud không thể là Matter node cho nhà dân. Cloud chỉ là kênh để app hiện mã QR từ xa.

**Thành phần**: Matterbridge (bridge mode, một mã ghép nối cho cả bridge) + plugin `matterbridge-zigbee2mqtt` đọc trực tiếp MQTT của Zigbee2MQTT. Image `infra/matterbridge` dựa trên `luligu/matterbridge` (amd64 + arm64), ghim phiên bản plugin, tự đăng ký plugin và tạo config ở lần chạy đầu (`entrypoint.sh`), `blackList: ["Coordinator"]` (plugin mặc định đưa coordinator ra Matter dạng khoá cửa để mở ghép nối Zigbee, không muốn controller bên thứ ba làm được việc đó).

**Ánh xạ thiết bị** (đã kiểm chứng bằng simulator, log Matterbridge 3.11.2 / plugin 3.3.1): công tắc 1 gang → `OnOffLight`; 2/3 gang → endpoint cha có các endpoint con `OnOffLight` (`state_1`, `state_2`...); cảm biến cửa → `ContactSensor`; cảm biến hiện diện → `OccupancySensor`. Mặc định plugin đưa công tắc ra dạng `OnOffLightSwitch` (kiểu thiết bị *điều khiển*); `autolist.mjs` đọc `bridge/devices` lúc khởi động và điền `lightList` để Home app coi là đèn (`MATTER_SWITCH_AS=outlet|switch` để đổi). Chưa kiểm chứng Apple/Google hiển thị kiểu `OnOffLightSwitch` thế nào, nên mặc định chọn `light`.

**Luồng mã QR**: app → `GET /v1/homes/:id/matter` (admin) → backend gửi `matter_get` xuống gateway (WebSocket, có `id` tương quan, chờ tối đa 15s) → gateway mở WebSocket cục bộ tới Matterbridge (`/api/matter`) → trả `qrPairingCode` (`MT:…`) và mã 11 số → backend kiểm tra định dạng rồi trả cho app. Không lưu DB, không ghi log; trả `Cache-Control: no-store`. Gateway chỉ trả mã khi bridge chưa ghép lần nào hoặc cửa sổ ghép nối đang mở. Phản hồi chỉ được chấp nhận từ đúng gateway đã nhận yêu cầu.

**Xác thực Matterbridge**: frontend/API dùng mật khẩu (mặc định **rỗng**) và chỉ nhớ theo IP, nên phải giữ nội bộ (bind `127.0.0.1`, hoặc mạng compose + publish loopback). Gateway dùng `MATTERBRIDGE_PASSWORD` nếu bạn đặt mật khẩu.

**Chưa kiểm chứng**: ghép thật với Google Home / Apple Home (môi trường dev không có mDNS ra LAN), độ ổn định trên Pi 3 (RAM 1 GB: Z2M + Mosquitto + gateway + Matterbridge/Node.js), cách Home app hiển thị công tắc nhiều gang. Matterbridge và plugin cập nhật thường xuyên; nâng phiên bản có chủ đích và thử lại.

## 7. Raspberry Pi 3

1 GB RAM: đủ cho Mosquitto + Z2M + gateway (agent Rust dùng rất ít). Dùng OS 64-bit, build image `linux/arm64` bằng `docker buildx` trên máy dev thay vì biên dịch trên Pi. Dùng thẻ nhớ chất lượng tốt hoặc SSD USB (Z2M ghi DB liên tục).

## 8. Việc còn lại (theo thứ tự đề xuất)

1. Thử với dongle + công tắc VSmart thật; chốt model/endpoint; điều chỉnh `serial.adapter`.
2. Chạy app trên emulator/thiết bị thật (chưa chạy), kiểm tra luồng đăng nhập → bật/tắt → realtime.
3. Test tự động cho backend (phân quyền, validate lệnh, đồng bộ thiết bị) với Postgres thật. Hiện chỉ có test đơn vị cho giới hạn tốc độ và JWT (`cargo test`) và test luồng làm mới token của app (`flutter test`).
4. Các mục bảo mật còn thiếu ở §5.
5. Chọn phương án Cloudflare §4 và dựng CI/CD.
6. Tính năng tiếp: cảnh (scene), lịch hẹn giờ, push notification, OTA gateway, giám sát tiêu thụ.
