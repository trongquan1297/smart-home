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

## 4c. Khách thuê (vai trò `renter`)

Thứ tự vai trò: guest < **renter** < member < admin < owner. `home_members` có thêm `valid_from`, `valid_until`, `duration_hours` (migration 0006, ràng buộc CHECK: chỉ `renter` mới có cửa sổ). `access::home_role` coi khách thuê ngoài `[valid_from, valid_until)` như không có quyền (404), nên mọi endpoint tự động chặn đúng lúc, không cần job dọn nền. Thời gian tính bằng đồng hồ của Postgres.

- Cửa sổ bắt đầu khi khách chấp nhận lời mời (hoặc `starts_at` nếu còn ở tương lai). "Cấp quyền ngay" đặt lại cửa sổ từ bây giờ với đủ `duration_hours`; "Gia hạn" cộng nối tiếp (hết hạn thì tính từ bây giờ).
- Hạn chế quyền nằm ở backend (không chỉ ẩn nút trong app): `command` yêu cầu tối thiểu `renter` và từ chối khoá không bắt đầu bằng `state`; chạy ngữ cảnh cần `member`; danh sách thành viên trả 403 cho khách thuê.
- Cắt realtime: mỗi phiên WebSocket của app kiểm tra lại quyền mỗi 10 giây, và ngay khi nhận tín hiệu nội bộ `access_check` (backend phát lên kênh của căn hộ sau khi mời/thu hồi/cấp/gia hạn). Mất quyền thì gửi `{"type":"access_revoked"}` rồi đóng.
- Chờ check-in: `GET /v1/homes` vẫn trả căn hộ cho khách thuê chưa tới giờ (`access_status = "scheduled"`, `access_from`, `access_until`, `address = null`) để app hiện đếm ngược; hết hạn thì ẩn. Mọi endpoint dữ liệu vẫn qua `access::home_role` nên trả 404 cho tới đúng giờ. App coi máy chủ là nguồn sự thật: khi đồng hồ máy về 0 mà máy chủ chưa báo `active` thì thử lại mỗi 5 giây.
- Giới hạn: lệnh khách thuê vẫn ghi vào `command_log` (có `user_id`), nhưng chưa có màn hình xem nhật ký; thu hồi = xoá dòng thành viên, không lưu lịch sử khách; một người một cửa sổ trên mỗi căn hộ (mời lại sẽ đặt lại cửa sổ).

## 4a. Đa hãng: phân loại theo `exposes`

`kind_of` (backend/src/gateway_ws.rs) phân loại thiết bị theo cấu trúc exposes của Zigbee2MQTT: `light`, `switch`, `cover`, `sensor`, `other`; không có logic riêng theo hãng, nên thêm hãng mới không cần sửa backend. Whitelist lệnh gồm `state*` (ON/OFF/TOGGLE/OPEN/CLOSE/STOP), `brightness*`, `color_temp*`, `position` (0–100). App đọc thêm đơn vị của từng thuộc tính từ exposes (vd `voltage` đơn vị mV là điện áp pin nên bị bỏ qua, chỉ hiện khi đơn vị là V).

Lỗi thật tìm ra khi thử nhiều thiết bị: gateway dùng giới hạn gói MQTT mặc định của rumqttc (10 KB) trong khi bản tin retained `bridge/devices` lớn dần theo số thiết bị (mỗi thiết bị mang cả cây exposes; 10 mẫu đã ~17 KB). Vượt ngưỡng thì gateway bị ngắt và kết nối lại vô hạn, không bao giờ đồng bộ. Đã nâng giới hạn lên 4 MiB (`MQTT_MAX_PACKET`). Gateway còn đọc `MQTT_CLIENT_ID` (mặc định `smart-gateway`) vì hai gateway dùng chung broker với cùng client id sẽ đá nhau.

## 4b. Ngữ cảnh và tự kích hoạt

Bảng `scenes` (migration 0005): `actions` jsonb `[{device_id, payload}]` (không có FK tới `devices`: thiết bị bị xoá thì hành động đó bị bỏ qua khi chạy), cộng cột tự kích hoạt `auto_enabled/auto_time/auto_days` và `last_run_at/last_status`. Bộ chạy (`backend/src/automation.rs`) là một task nền trong tiến trình backend, **không** nằm trên Pi, nên cần backend và gateway cùng online lúc đến giờ.

- Tính giờ: `due_instant` đổi giờ địa phương của căn hộ sang UTC (xét cả "hôm nay" và "hôm qua" để không lọt lịch vắt qua nửa đêm; giờ không tồn tại do nhảy giờ mùa hè thì bỏ qua; múi giờ sai thì dùng Asia/Ho_Chi_Minh).
- Chống chạy đôi: `UPDATE … WHERE last_run_at < <thời điểm định>` trả về đúng 1 dòng mới được chạy, nên an toàn khi có nhiều bản backend. Tạo/sửa giờ đặt `last_run_at = now()` để không chạy bù lần đã qua trong ngày.
- Gateway offline: thử lại ở các tick sau trong 5 phút (`GRACE_SECS`), quá hạn ghi `missed`. Chọn bỏ lỡ thay vì chạy bù vì bật/tắt thiết bị trễ nhiều giờ có thể gây hại hơn là bỏ qua.
- Bật/tắt lần lượt (migration 0017, `scenes.step_delay_ms` 0–10000): `automation::run_scene_actions` tách payload mỗi thiết bị thành từng bước theo gang (`split_by_channel`: `state_N` đi cùng `brightness_N`/`color_temp_N`), gửi theo thứ tự hành động rồi thứ tự gang, ngủ `step_delay_ms` giữa hai bước có tác dụng (bước mà `devices.state` đã khớp thì gửi lại nhưng không chờ). Mỗi lượt chạy ghi id vào `AppState.scene_runs` (căn hộ → lượt mới nhất, RAM một tiến trình); trước mỗi bước kiểm tra còn là lượt mới nhất, không thì dừng — nên chạy ngữ cảnh khác giữa chừng không bị lệnh cũ ghi đè. Chạy tay có giãn cách: kiểm tra gateway, đặt "đang bật", chạy nền và trả `{"status":"running","sent":total}` (`sent` = `total` để app cũ vẫn báo thành công). Bộ lập lịch và "rời nhà" luôn chạy nền (`tokio::spawn`) để vòng lặp 20 giây và yêu cầu `presence` của điện thoại không phải chờ. `command_log` ghi từng bước. Luật ⚡ (`rules.rs`) vẫn dùng `execute` gửi ngay, không tham gia `scene_runs`.
- Giới hạn đã biết: độ chính xác ±20 giây (chu kỳ tick); lệnh chỉ "đã gửi xuống gateway", chưa chờ thiết bị xác nhận nên `ok` nghĩa là đã gửi đủ lệnh chứ không đảm bảo thiết bị đã đổi trạng thái; ngữ cảnh chạy bằng tay và lệnh điều khiển thường dùng chung bảng `command_log`.

## 4d. Cảnh báo cảm biến và thông báo đẩy

Migration 0007: `scenes.alert_devices uuid[]`, `homes.active_scene_id/active_since` (FK `ON DELETE SET NULL`), `push_tokens`, `notifications`. Chạy ngữ cảnh (tay hoặc bộ lập lịch) đặt `active_scene_id`; ngữ cảnh không có cảnh báo thay thế cái cũ nên cũng là cách tắt canh.

- Phát hiện (`backend/src/alerts.rs`): handler `State` của gateway cập nhật `devices.state` bằng CTE `UPDATE … RETURNING` lấy cả trạng thái cũ và mới, so sánh `occupancy` false→true / `contact` true→false (chỉ chuyển trạng thái mới tính, không phải mọi bản tin). Chỉ báo khi thiết bị nằm trong `alert_devices` của ngữ cảnh đang bật. Chống trùng 60 giây theo (thiết bị, loại) bằng DashMap trong RAM — nhiều bản backend sẽ mỗi bản một bộ đếm.
- Phát: ghi `notifications` (giữ 30 ngày) → WebSocket `alert` (bỏ qua với vai trò dưới member) → FCM HTTP v1 (`push.rs`, JWT RS256 từ service account, tuỳ chọn qua `FCM_SERVICE_ACCOUNT_FILE`; người nhận = owner/admin/member của căn hộ + quản trị tenant). Lỗi FCM chỉ ghi log, không chặn luồng trạng thái; token bị FCM báo không còn hợp lệ (`UNREGISTERED`/404) bị xoá khỏi `push_tokens`.
- App: `Notifier` (thông báo cục bộ khi nhận `alert` qua WS lúc app đang chạy) và `PushService` (Firebase, đăng ký token qua `POST /v1/push/tokens` sau khi người dùng cấp quyền; không xử lý tin FCM lúc foreground để khỏi báo trùng với WS). Dùng `getToken()` (đã deprecated) thay vì `register()/onRegistered` vì API mới trả về Firebase Installation ID, chưa kiểm chứng dùng được làm đích HTTP v1.
- Còn thiếu: chưa có "giờ yên tĩnh"; trạng thái canh chỉ theo ngữ cảnh, không theo người.

## 4e. Tự chuyển ngữ cảnh khi rời nhà

Migration 0008: `homes.geo_lat/geo_lng/geo_radius_m`, `scenes.auto_leave` (ban đầu tối đa 1 ngữ cảnh mỗi căn hộ; migration 0018 bỏ giới hạn này, xem §4e2), `member_presence(home_id, user_id, inside, updated_at)`. Logic ở `backend/src/presence.rs`: `report` tính `home_presence` trước và sau khi ghi; chuyển có người → không còn ai gọi `triggers::on_presence(Leave)`, ngược lại gọi `on_presence(Arrive)`. `home_presence` chỉ đếm hàng `inside` mới hơn 7 ngày của người còn là owner/admin/member (hoặc quản trị tenant), nên thành viên bị gỡ hoặc điện thoại chết không chặn mãi.

- Riêng tư: máy chủ chỉ biết vị trí căn hộ do quản trị đặt và cờ trong/ngoài của từng người; toạ độ của thành viên ở lại trên điện thoại (geofence do hệ điều hành đánh giá).
- App (`geofence_service.dart`): `native_geofence` với callback top-level `homeGeofenceTriggered` chạy trong isolate nền, tự đọc `token`/`refresh_token` từ `flutter_secure_storage` rồi gọi `presence`. Rủi ro đã biết: nếu app đang mở và callback nền cùng làm mới token một lúc thì refresh token xoay vòng bị coi là dùng lại và thu hồi cả phiên (hiếm; chưa có khoá chéo giữa hai isolate). `AppModel.refreshGeofence` đăng ký/gỡ theo cấu hình (chỉ khi căn hộ có vị trí và có ngữ cảnh `auto_leave`) và báo ngay trạng thái hiện tại để máy chủ có mốc "trong".
- Thông báo khi tự chạy: `alerts::scene_auto_ran` (gọi từ `run_due` và `triggers::fire`) ghi `notifications` kind `scene_auto`/`scene_failed`, publish WS `alert`, gửi FCM — cùng đường với cảnh báo cảm biến.
- Chưa làm: kích hoạt khi **về** nhà, nhiều vùng cho một căn hộ, thử lại khi gateway offline lúc rời nhà.

## 4e2. Điều kiện tự kích hoạt ngữ cảnh (HOẶC / VÀ)

Migration 0018: `scenes.trigger_logic ('any'|'all')`, `auto_time_end`, `auto_arrive`, `trigger_sensors jsonb [{device_id, event}]` (chỉ mục GIN), bỏ `scenes_one_auto_leave`. Logic ở `backend/src/triggers.rs`; điều kiện cũ (`auto_enabled/auto_time/auto_days`, `auto_leave`) giữ nguyên cột nên app bản cũ vẫn tương thích.

- Mỗi điều kiện có **sự kiện** và **trạng thái**. Điểm vào sự kiện: `automation::run_due` (hẹn giờ, giữ cơ chế giành lượt/grace/missed như §4b), `triggers::on_presence` (gọi từ `presence::report` khi `home_presence` chuyển `Some(true)↔Some(false)`; `None` = chưa ai báo → không phải sự kiện), `triggers::on_state` (gọi từ handler `State` của gateway sau alerts/rules/purifier; lọc nhanh bằng `sensor_event` rồi truy vấn `trigger_sensors @> [{device_id}]`).
- `others_hold(cond, fired)`: với `all`, kiểm tra mọi điều kiện khác `fired` đang đúng — `in_window` (khung giờ theo múi giờ căn hộ, qua nửa đêm, mốc không có giờ kết thúc = 300 s), `home_presence` (rời = `Some(false)`, về = `Some(true)`), `sensor_state` đọc `devices.state`. Với `any` luôn đúng.
- Chạy: `fire` giành lượt bằng `UPDATE … WHERE last_run_at < now() - 60s` (không tính `last_status` NULL do tạo/sửa đặt `last_run_at = now()`, hay `missed`/`skipped` vì không gửi lệnh), rồi `run_scene_actions` (giãn cách/huỷ lượt như §4b), `activate_scene`, `alerts::scene_auto_ran` với `AutoRun::{Schedule, Leave, Arrive, Sensor}`. Hẹn giờ + VÀ chưa đủ điều kiện → `last_status = 'skipped'` cho mốc đó.
- `skip_if_active` (migration 0019): `Cond::skip_because_active` (`COND_SELECT` lấy `COALESCE(h.active_scene_id = s.id, false)`) bỏ qua sự kiện rời/về/cảm biến (log `info`) và hẹn giờ (ghi `skipped`); `fire` kiểm tra lại ngay trong câu UPDATE giành lượt (`AND NOT (skip_if_active AND EXISTS(… active_scene_id = scenes.id))`) nên hai sự kiện đồng thời không lọt. Chạy tay (`run_scene`) không xét cờ này.
- Kiểm tra khi tạo/sửa (`check_trigger_combo`, sau khi gộp với giá trị đang lưu): `all` + ≥2 điều kiện thì hẹn giờ phải có `auto_time_end` và không được vừa rời vừa về; cảm biến phải thuộc căn hộ và có `occupancy`/`contact` đúng loại sự kiện; rời/về cần căn hộ có vị trí.
- Giới hạn đã biết: trạng thái rời/về chỉ đúng khi thành viên chia sẻ vị trí (geofence app); cảm biến pin báo trễ có thể làm VÀ "đang đúng" theo trạng thái cũ; chưa có điều kiện theo nhiệt độ/độ ẩm, mặt trời, hay "giữ trạng thái N phút"; chưa có nhật ký "vì sao không chạy" cho sự kiện rời/về/cảm biến (chỉ ghi log `info`).

## 4f. Luật tự động theo thiết bị

Migration 0009: `device_rules(kind auto_off|auto_on|link, key, delay_s, source_*, target_state, enabled)` (chỉ mục duy nhất từng phần: mỗi (thiết bị, gang) một luật mỗi loại hẹn giờ) và `pending_actions(rule_id PK, due_at, state)`. `rules::on_state` được gọi sau `alerts::on_state` trong handler `State` của gateway với trạng thái cũ/mới: `transitions` chỉ tính ON↔OFF của khoá `state*` khi đã có trạng thái cũ (bản tin đầu tiên, rèm OPEN/CLOSE bị bỏ qua). Chuyển sang ON: huỷ hẹn `auto_on`, hẹn `auto_off` (upsert theo `rule_id` nên bật lại thì tính lại giờ); chuyển sang OFF: ngược lại. `rules::runner` quét `pending_actions` mỗi giây; chỉ gửi nếu gang chưa ở trạng thái đích; gateway offline quá 60 giây thì bỏ.

- Chống vòng lặp: lệnh do luật phát được ghi vào `AppState.rule_cmds` (thiết bị, gang) → (trạng thái, thời điểm); bản tin phản hồi trong 20 giây khớp trạng thái đó **không** kích hoạt luật `link` (không nối chuỗi), nhưng vẫn được tính cho hẹn giờ (vd link bật gang B rồi B có luật tự tắt vẫn chạy). `rule_cmds` nằm trong RAM của một tiến trình backend.
- Đổi cấu hình luật (PATCH) xoá hẹn giờ đang chờ của luật đó; xoá luật/thiết bị xoá hẹn giờ theo (CASCADE).
- Chưa làm: luật cho rèm (OPEN/CLOSE), điều kiện theo giờ trong ngày, trễ cho luật `link`, nhật ký "luật đã chạy" trong lịch sử thông báo.

## 4g. Thông báo giọng nói (Google Cast)

Migration 0010: `speakers(home_id, name, cast_id, host, port)` (`cast_id` = TXT `id` của mDNS, ổn định; `host` chỉ là địa chỉ lần cuối) và cột `speaker_ids uuid[]`, `speak_text` trên `scenes` và `device_rules`. `backend/src/speak.rs`: CRUD loa, `scan` (gửi `cast_scan` xuống gateway bằng `hub.request_gateway`, nhận `cast_reply`), `say` (gửi `speak` fire-and-forget xuống gateway của căn hộ). Điểm gọi: `alerts::scene_auto_ran` (ngữ cảnh tự chạy thành công) và `rules.rs` (`run_due` cho hẹn giờ, `handle` cho `link`; chỉ khi thật sự đã gửi lệnh, không đọc khi gang đã ở trạng thái đích).

Gateway (`gateway/src/cast.rs`): luồng mDNS (`mdns-sd`) giữ danh sách loa đang thấy; `speak` tải mp3 một lần (`reqwest`, `TTS_URL_TEMPLATE`), mỗi loa một hàng đợi (`tokio::Mutex` theo cast_id), đăng ký tệp với tên ngẫu nhiên 128 bit (hết hạn sau 5 phút) trong máy chủ HTTP tối giản (hỗ trợ Range), tự chọn địa chỉ LAN của Pi bằng UDP connect tới IP loa (hoặc `CAST_ADVERTISE_HOST`), rồi nói CASTV2 tự viết (protobuf `prost` + `tokio-rustls` bỏ kiểm tra chứng chỉ vì loa dùng chứng chỉ tự ký): CONNECT → LAUNCH `CC1AD845` → CONNECT tới transportId → LOAD → chờ `IDLE/FINISHED` (trả lời PING, gửi PING định kỳ) → STOP.

- Nhiều gateway một căn hộ: gateway khai báo `hello {caps: [z2m, cast]}` ngay sau khi kết nối; `Hub::gateway_for_home` (Matter, trạng thái "online") bỏ qua gateway chỉ có `cast`; `scan` hỏi mọi gateway `cast` song song rồi gộp theo `cast_id`, gắn `gateway_id` đã thấy loa; `say` gom loa theo `speakers.gateway_id` (migration 0011) và chỉ gửi cho gateway đó. Gateway cũ chưa gửi `hello` được coi là Zigbee, không cast.
- Giới hạn/rủi ro: TTS là endpoint không chính thức; CASTV2 chưa thử với thiết bị thật; phát tin làm gián đoạn nhạc đang chạy trên loa; không có hàng đợi bền (gateway mất kết nối hoặc loa tắt lúc đó thì câu bị bỏ); loa phải cùng LAN và truy cập được cổng HTTP của gateway; backend ghi nhận loa theo gateway đầu tiên của căn hộ (`gateway_for_home`).
- Chưa làm: chọn giọng/tốc độ, âm lượng, cảnh báo khẩn cấp ưu tiên ngắt nhạc, đọc cho thông báo cảm biến (chỉ ngữ cảnh/luật tự chạy), Google Cloud TTS chính thức.

## 4h. Addon trong nhà — camera (go2rtc + ONVIF)

Một addon duy nhất (`addons/msmart`, một token gateway) cho mọi thiết bị không đi qua Zigbee; mỗi loại thiết bị là một module và một khả năng trong `hello.caps` (`camera`, `purifier`). Phần dưới là module camera.

```
 App ──HTTPS (SDP, ảnh, PTZ)──▶ Backend ◀──WSS (outbound)── msmart-addon ──HTTP 127.0.0.1──▶ go2rtc ──RTSP──▶ camera
  └──────────────── WebRTC (UDP/TCP 8555, ngang hàng) ─────────────────────────────────────────┘     ▲ ONVIF (PTZ, sự kiện)
```

- Addon là một gateway khai báo `caps: ["camera", "purifier"]` (theo `ADDON_DEVICES`). Hub không coi nó là gateway Zigbee (`gateway_for_home`/`gateway_online` bỏ qua gateway có khai báo khả năng nhưng không có `z2m`).
- Bản tin cloud → addon: `cam_scan`, `cam_add`, `cam_remove`, `cam_webrtc`, `cam_snapshot` (chờ `cam_reply` cùng `id`, như `matter_*`), `cam_ptz` (không chờ). Addon → cloud: `cam_list` (khi kết nối), `cam_status`, `cam_event` (`motion`). Backend chỉ nhận sự kiện/trạng thái cho camera thuộc đúng addon gửi.
- Mật khẩu camera đi qua RAM của backend đúng một lần (lúc thêm) rồi chỉ addon lưu. go2rtc nhận URL RTSP qua API, file cấu hình go2rtc gắn chỉ-đọc nên mật khẩu không bị ghi vào đó (go2rtc trả 400 khi không lưu được cấu hình — addon xác nhận luồng bằng `GET /api/streams`). API go2rtc không có xác thực khi gọi từ localhost nên chỉ nghe `127.0.0.1`; RTSP của go2rtc tắt.
- go2rtc không có PTZ và phát hiện chuyển động (đã đối chiếu tài liệu go2rtc v1.9.15): addon tự làm ONVIF (WS-Security PasswordDigest, bù lệch giờ camera bằng GetSystemDateAndTime).
- **Chưa kiểm chứng với camera thật**: chỉ thử với camera ONVIF giả lập (`infra/camera-sim`). Camera thật có thể khác ở: xác thực HTTP Digest thay cho WS-Security, tên chủ đề/trường sự kiện chuyển động, PullPoint cần header WS-Addressing khác, giới hạn số subscription.

## 5. Bảo mật — đã làm / còn thiếu

Đã có: mật khẩu argon2 (tối đa 4 lần băm đồng thời để không bị bóp RAM/CPU); gateway/invite token 256-bit chỉ lưu hash SHA-256, hiển thị 1 lần; mã mời dùng 1 lần có hạn; whitelist payload lệnh; agent từ chối tên thiết bị chứa `/ # +` (chống topic injection); container chạy non-root; người ngoài nhận 404; và ba mục dưới đây.

### Mosquitto: bắt buộc đăng nhập + ACL

`allow_anonymous false`, mỗi dịch vụ một tài khoản riêng (`infra/mosquitto/acl.conf`):

| Tài khoản | Quyền |
|---|---|
| `z2m` (Zigbee2MQTT thật hoặc simulator) | đọc/ghi `zigbee2mqtt/#` |
| `gateway` | đọc `zigbee2mqtt/#`; chỉ ghi `zigbee2mqtt/+/set` và `zigbee2mqtt/bridge/request/permit_join` (ghép thiết bị từ app, chỉ quản trị căn hộ gọi được); không giả mạo trạng thái, không gọi các `bridge/request/*` khác |
| `matterbridge` | đọc/ghi `zigbee2mqtt/#` (xem lưu ý dưới) |

File mật khẩu do `infra/mosquitto/entrypoint.sh` tạo mỗi lần khởi động từ biến `MQTT_PASSWORD_Z2M/_GATEWAY/_MATTERBRIDGE` (thiếu hoặc <16 ký tự thì broker từ chối chạy), nên repo không chứa mật khẩu nào. Trên Pi: `cd edge && ./gen-secrets.sh` sinh mật khẩu ngẫu nhiên 256-bit vào `edge/.env` (chmod 600, không ghi đè mật khẩu đã có). Compose dev dùng mật khẩu `dev-only-*` vì cổng chỉ mở ở `127.0.0.1`.

Đã kiểm chứng trong dev: ẩn danh và sai mật khẩu bị từ chối; `gateway` không đọc được `$SYS`, publish được `…/set` và `…/bridge/request/permit_join` nhưng `…/bridge/request/device/remove`, topic ngoài cây và ghi đè trạng thái thiết bị đều bị chặn; simulator, gateway và Matterbridge kết nối bình thường. **Chưa kiểm chứng**: Zigbee2MQTT thật đọc `ZIGBEE2MQTT_CONFIG_MQTT_USER/PASSWORD` (tên biến suy ra từ quy tắc trong tài liệu Z2M, tài liệu không liệt kê riêng hai biến này; nếu Z2M báo lỗi đăng nhập thì chuyển sang `secret.yaml`); và plugin Matterbridge cần ghi những topic nào khi Home app điều khiển (nên cấp rộng `zigbee2mqtt/#`, thu hẹp thì phải thử lại).

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
6. Tính năng tiếp: OTA gateway, giám sát tiêu thụ.
