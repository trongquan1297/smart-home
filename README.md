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
| `addons/msmart/` | **Addon trong nhà duy nhất** (Rust, một container, một token): mọi thiết bị không đi qua Zigbee — hiện có camera Wi‑Fi (go2rtc + ONVIF — xem trực tiếp, PTZ, cảnh báo chuyển động) và máy lọc nước Karofi qua Bluetooth |
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

## Triển khai lên máy chủ (đã làm: 10.60.1.14)

Thư mục `/opt/msmart` (SSH: `ssh -J root@113.20.103.158 root@10.60.1.14`), project Docker `smarthome`, chạy cùng máy với các dịch vụ khác nên **không dùng 8080/8081/5432** (thuộc `shop-api` và Postgres 13).

| Dịch vụ | Cổng | Ghi chú |
|---|---|---|
| Backend | **18080**, chỉ nhận kết nối từ máy chuyển tiếp Cloudflare `10.60.1.231` | Công khai qua `https://msmart-api.newmoon.cloud` (Cloudflare). `TRUSTED_IP_HEADER=CF-Connecting-IP`; tường lửa: `/usr/local/sbin/msmart-firewall.sh` + `msmart-firewall.service` (luật trong `DOCKER-USER`). Đổi máy chuyển tiếp thì sửa `PROXY=` trong script rồi `systemctl restart msmart-firewall` |
| Simulator Zigbee2MQTT | **18081** (mọi giao diện) | giao diện web **không có xác thực** |
| Postgres | không publish | chỉ backend trong mạng compose truy cập |
| Mosquitto | `127.0.0.1:1883` | |

Cấu hình nằm trong `.env` (chmod 600, mật khẩu ngẫu nhiên sinh trên server, không có trong repo) và `docker-compose.server.yml`. Lệnh thường dùng trên server: `docker compose ps`, `docker compose logs -f backend`, `docker compose up -d --build backend`.

**Gateway chưa chạy** (cần token): đăng ký tài khoản trong app (`--dart-define=API_URL=http://<địa-chỉ-công-khai>:18080`), tạo căn hộ, vào *Bộ điều khiển trung tâm → Thêm*, dán token vào `GATEWAY_TOKEN=` trong `.env` rồi `docker compose up -d --build gateway`. Chưa tạo dữ liệu mẫu và **không** có tài khoản demo trên server.

## Khách thuê: chia sẻ quyền có thời hạn

Quản trị căn hộ: **Thành viên → Mời thành viên → Khách thuê**. Chọn thời gian dùng (6 giờ … 30 ngày hoặc nhập số giờ, tối đa 8760) và giờ bắt đầu (*khi khách nhập mã*, hoặc *hẹn giờ* tới 1 năm). Gửi mã mời cho khách; khách nhập mã ở màn Căn hộ như thành viên thường.

- **Chỉ bật/tắt**: lệnh của khách thuê chỉ nhận `state*` (ON/OFF/TOGGLE, và OPEN/CLOSE/STOP của rèm); chỉnh độ sáng, màu, vị trí rèm bị từ chối (403). Khách xem được phòng và thiết bị, nhưng không chạy được ngữ cảnh, không xem danh sách thành viên (có email gia đình), không vào Matter/gateway/mời/sửa thiết bị.
- **Hết giờ là hết quyền**: quyền được kiểm tra ở **mỗi** yêu cầu nên có hiệu lực tức thì ở REST; WebSocket đang mở bị cắt tối đa ~10 giây sau khi hết hạn, và **ngay lập tức** khi bị thu hồi/cấp/gia hạn. App tự thoát về danh sách và báo "Quyền truy cập … đã kết thúc".
- **Can thiệp ngay lập tức** (chỉ quản trị): *Cấp quyền ngay* (mở sớm khi đã hẹn giờ, hoặc cấp lại đủ thời lượng khi đã hết hạn), *Gia hạn* (+1 giờ … +7 ngày), *Thu hồi ngay* (nút đỏ).
- **Đợi check-in**: nếu quản trị hẹn giờ bắt đầu, khách đăng nhập và nhập mã sẽ thấy thẻ căn hộ **"Khách thuê · đang đợi check-in"** với đồng hồ đếm ngược từng giây và giờ check-in; hộp thoại xác nhận báo giờ vào được. Chưa tới giờ thì mọi dữ liệu căn hộ đều bị chặn (404) và **địa chỉ căn hộ bị ẩn**; tới giờ thẻ tự mở, không cần thao tác. Máy chủ quyết định trạng thái (đồng hồ điện thoại lệch chỉ làm hiển thị "Đang kích hoạt…" vài giây rồi app hỏi lại máy chủ mỗi 5 giây).
- Khách thuê đã là thành viên chính thức thì không bị hạ quyền (409); khách thuê nhận lời mời thành viên sẽ được nâng quyền và xoá giới hạn thời gian.
- API: `POST /v1/homes/:id/invites {role:"renter", duration_hours, starts_at?}`, `PATCH /v1/homes/:id/members/:uid {action:"grant_now"|"extend", hours?}`, `DELETE /v1/homes/:id/members/:uid` (thu hồi). Vai trò trong code là `renter` (không dùng "tenant" vì chữ đó đã là khách hàng của hệ thống).

## Thiết bị nhiều hãng (Aqara, Tuya, VSmart…)

Hệ thống đi qua **Zigbee2MQTT**, nên mọi thiết bị **Zigbee** mà Zigbee2MQTT hỗ trợ (danh sách ở zigbee2mqtt.io/supported-devices) ghép được bằng *Permit join* như thiết bị VSmart. Backend và app xử lý theo cấu trúc `exposes` mà thiết bị báo, không theo tên hãng:

| Loại | Nhận diện | App hiển thị / điều khiển |
|---|---|---|
| Công tắc, ổ cắm | expose `switch` (`state`, `state_1`, `state_l1`, `state_left`/`state_right`…) | từng gang bật/tắt; nhãn "Gang trái/phải", "Gang N", "Ổ cắm" |
| Ổ cắm đo điện | switch + `power`, `current`, `voltage` (V), `energy` | thêm ô Công suất, Dòng điện, Điện áp, Điện năng |
| Rèm / cửa cuốn | expose `cover` (`state` OPEN/CLOSE/STOP, `position` 0–100) | nút Mở · Dừng · Đóng, thanh trượt vị trí |
| Cảm biến | `temperature`, `humidity`, `pressure`, `illuminance`, `contact`, `occupancy`, `water_leak`, `smoke`, `vibration`, `battery` | ô số liệu; rò nước/khói/cửa mở được tô nổi bật |

Đã thử trong **simulator** với các mẫu (thuộc tính lấy theo trang thiết bị trên zigbee2mqtt.io): Aqara `WSDCGQ11LM`, `RTCGQ11LM`, `SJCGQ11LM`, `MCCGQ11LM`, `QBKG03LM`, `ZNCZ12LM`; Tuya `TS0012`, `TS0201`, `TS011F_plug_1`, `TS130F`. **Chưa thử với thiết bị Aqara/Tuya thật.**

Chưa hỗ trợ: **Tuya Wi‑Fi** (không phải Zigbee, cần Tuya Cloud/LocalTuya, ngoài phạm vi), thanh trượt độ sáng/màu cho đèn, điều hòa/van sưởi (`climate`), khoá, quạt, nút bấm (`action`). Thiết bị loại này vẫn ghép và hiện tên, nhưng app chưa có điều khiển riêng. Việc ánh xạ sang Matter (Google/Apple Home) cho rèm và cảm biến phụ thuộc plugin `matterbridge-zigbee2mqtt`, chưa kiểm chứng. Lưu ý riêng từ trang thiết bị: Tuya `TS0201` có firmware OTA mới được báo là làm hỏng thiết bị, không nên cập nhật.

## Ngữ cảnh và tự kích hoạt

Trong app: căn hộ → biểu tượng ✨ **Ngữ cảnh**. Một ngữ cảnh là nhóm thao tác Bật/Tắt theo từng gang của nhiều công tắc (vd "Đi ngủ" tắt hết đèn); bấm ▶ để chạy ngay, hoặc bật **Tự động kích hoạt** để chọn giờ và các ngày trong tuần. Giờ tính theo múi giờ của căn hộ (`homes.timezone`, mặc định Asia/Ho_Chi_Minh).

- Backend chạy vòng lặp nền 20 giây/lần; mỗi lần đến giờ được "giành" bằng một câu UPDATE có điều kiện nên không chạy đôi.
- Bộ điều khiển trung tâm (Pi) offline lúc đến giờ: thử lại trong 5 phút; quá hạn thì ghi **bỏ lỡ** (hiện trên thẻ ngữ cảnh), **không chạy bù muộn**. Backend tắt đúng lúc đến giờ cũng bị coi là bỏ lỡ.
- Chỉ nhận `ON`/`OFF` (không `TOGGLE`, để chạy lại cho cùng kết quả); payload đi qua đúng whitelist của lệnh điều khiển; lệnh tự động ghi `command_log` với `user_id` rỗng.
- **Bật/tắt lần lượt** (mục trong form ngữ cảnh): chọn *Cùng lúc* (mặc định) hoặc giãn cách 0,5 / 1 / 2 / 3 / 5 giây. Khi chạy, từng gang (từng bóng đèn) được gửi lần lượt theo thứ tự trong danh sách thay vì bật/tắt đồng loạt; gang đã ở đúng trạng thái thì bỏ qua, không phải chờ. Chạy tay thì app nhận phản hồi ngay ("Đang chạy lần lượt…") còn lệnh tiếp tục gửi nền; chạy một ngữ cảnh khác của căn hộ trong lúc đó sẽ dừng phần còn lại. Áp dụng cho cả chạy tay, theo giờ và khi rời nhà.
- Giới hạn: 50 ngữ cảnh/căn hộ, 50 hành động/ngữ cảnh. Chưa có kích hoạt theo mặt trời mọc/lặn.

### Điều kiện tự kích hoạt (HOẶC / VÀ)

Mục **Tự động kích hoạt** trong form ngữ cảnh gồm bốn loại điều kiện, bật bao nhiêu cũng được:

| Điều kiện | Sự kiện (khi nào "xảy ra") | Trạng thái (khi nào "đang đúng", dùng cho VÀ) |
|---|---|---|
| Hẹn giờ (`auto_time`, `auto_days`, tuỳ chọn `auto_time_end`) | đến giờ bắt đầu | đang trong khung giờ `[bắt đầu, kết thúc)` (qua nửa đêm nếu kết thúc ≤ bắt đầu); không có giờ kết thúc = 5 phút sau mốc |
| Rời nhà (`auto_leave`) | người cuối cùng rời căn hộ | không còn ai ở nhà |
| Về nhà (`auto_arrive`) | người đầu tiên về căn hộ | có người ở nhà |
| Cảm biến (`trigger_sensors`, tối đa 10) | cảm biến hiện diện chuyển sang *có người* / *hết người*, cảm biến cửa sang *mở* / *đóng* | cảm biến đang ở trạng thái đó |

- **Một điều kiện bất kỳ** (`trigger_logic: "any"`, mặc định): chạy khi bất kỳ sự kiện nào xảy ra.
- **Tất cả điều kiện** (`"all"`): chạy khi một sự kiện xảy ra **và** mọi điều kiện còn lại đang đúng. Ví dụ "Cửa mở VÀ 18:00–23:00 VÀ có người ở nhà" → bật đèn hành lang; "Có người VÀ rời nhà" → báo đột nhập. Khi kết hợp VÀ, hẹn giờ bắt buộc có giờ kết thúc; không được yêu cầu cùng lúc rời nhà và về nhà. Đến giờ mà điều kiện khác chưa đúng thì lượt đó ghi **bỏ qua** (`skipped`), không chờ, không chạy bù.
- Mỗi ngữ cảnh tự chạy tối đa một lần mỗi 60 giây (cảm biến nhấp nháy, nhiều điều kiện xảy ra cùng lúc). Sự kiện cảm biến chỉ tính khi trạng thái thật sự chuyển (gateway phát lại trạng thái lúc kết nối lại không kích hoạt gì).
- Rời/về nhà: chưa ai báo vị trí thì trạng thái là *chưa biết* (không đúng cho cả hai); lần báo "trong" đầu tiên chỉ đặt mốc, không phải "về nhà". Nhiều ngữ cảnh có thể cùng dùng rời nhà / về nhà (bỏ giới hạn một ngữ cảnh mỗi căn hộ từ migration 0018).
- Thông báo `scene_auto` nêu lý do ("Theo lịch 18:00", "Không còn ai ở nhà", "Có người vừa về nhà", "Cảm biến cửa: cửa vừa mở"); loa Cast đọc câu tương ứng nếu ngữ cảnh có chọn loa.
- App bản cũ vẫn sửa được hẹn giờ / rời nhà của ngữ cảnh; các trường mới giữ nguyên khi app cũ lưu.

## Cảnh báo cảm biến và thông báo đẩy

Trong màn hình tạo/sửa ngữ cảnh có mục **Cảnh báo cảm biến**: chọn cảm biến hiện diện (`occupancy`) và cảm biến cửa (`contact`) cần canh. Chạy ngữ cảnh đó (bằng tay hoặc theo giờ) thì nó thành **ngữ cảnh đang bật** của căn hộ (`homes.active_scene_id`, hiện chip "Đang bật" và dải trên màn hình căn hộ). Khi một cảm biến đã chọn chuyển trạng thái (có người: `occupancy` false→true; cửa mở: `contact` true→false), backend ghi vào bảng `notifications`, đẩy sự kiện `alert` qua WebSocket và gửi FCM tới thiết bị của chủ nhà/quản trị/thành viên. Chạy một ngữ cảnh khác (không có cảnh báo) hoặc bấm **Tắt cảnh báo** (`DELETE /v1/homes/:hid/active-scene`) là tắt canh. Khách thuê/khách xem không nhận cảnh báo. Mỗi (cảm biến, loại sự kiện) tối đa 1 thông báo/60 giây; lịch sử giữ 30 ngày (menu ⋮ → Thông báo).

Bật FCM thật (app tắt hẳn vẫn nhận): (1) thêm `app/android/app/google-services.json` và `app/ios/Runner/GoogleService-Info.plist` của project Firebase — package/bundle ID phải là `com.newmoon22.msmart`; (2) Firebase Console → Project settings → Service accounts → tạo khoá JSON, lưu thành `secrets/fcm.json` (đã gitignore) và chạy backend với `FCM_SERVICE_ACCOUNT_FILE=/run/secrets/fcm.json`; (3) iOS: tải APNs Authentication Key (.p8) lên Firebase → Cloud Messaging, bật capability Push Notifications cho App ID, chạy trên máy thật. Không có biến này, cảnh báo vẫn tới app đang chạy qua WebSocket (thông báo cục bộ).

## Tự chuyển ngữ cảnh khi rời nhà

Trong form ngữ cảnh có tuỳ chọn **Tự chuyển khi rời nhà** (quản trị): bấm "Dùng vị trí hiện tại" khi đang ở nhà để đặt vị trí căn hộ (`PUT /v1/homes/:id/location`, bán kính 100/150/300/500 m, mặc định 150), rồi bật tuỳ chọn (điều kiện **Về nhà** dùng cùng cơ chế, xem "Điều kiện tự kích hoạt"). Điện thoại của từng thành viên (chủ nhà/quản trị/thành viên) đăng ký geofence của hệ điều hành quanh vị trí đó (`native_geofence`: CLCircularRegion trên iOS, GeofencingClient trên Android; chạy cả khi app đã tắt) và chỉ báo **trong/ngoài** lên `PUT /v1/homes/:id/presence` — máy chủ không nhận toạ độ cá nhân. Khi trạng thái chung chuyển từ "còn người ở nhà" sang "không còn ai", máy chủ chạy ngữ cảnh đó (thành ngữ cảnh đang bật, ghi `command_log` với `user_id` rỗng).

- Quy tắc "người cuối cùng": chỉ tính thành viên đã báo trạng thái trong 7 ngày gần nhất và còn quyền; báo "ngoài" khi chưa ai từng báo "trong" thì không chạy gì; báo lặp lại không chạy lại; đổi hoặc xoá vị trí thì xoá trạng thái cũ.
- Cần quyền vị trí **"Luôn luôn"**: app xin khi lưu ngữ cảnh, và hiện dải nhắc trên màn hình căn hộ nếu thành viên khác chưa cấp. Đăng xuất sẽ gỡ geofence của máy.
- Thông báo: mỗi lần ngữ cảnh **tự** chạy (theo giờ hoặc khi rời nhà) máy chủ lưu thông báo `scene_auto` ("Đã tự chuyển sang …" + lý do), đẩy WebSocket `alert` và FCM tới chủ nhà/quản trị/thành viên như cảnh báo cảm biến. Rời nhà mà gateway offline thì báo `scene_failed`; lịch theo giờ không báo thất bại vì tự thử lại 5 phút. Chạy bằng tay không tạo thông báo.
- Giới hạn: gateway offline lúc rời nhà thì ngữ cảnh không chạy (ghi `failed`, không chạy bù); điện thoại hết pin/tắt định vị/không cấp quyền thì không báo được; callback nền dùng refresh token đã lưu, hiếm khi trùng với app đang mở có thể làm phiên bị thu hồi (xem §5 ARCHITECTURE).

## Luật tự động theo thiết bị (biểu tượng ⚡)

Trên thẻ công tắc/đèn/ổ cắm (quản trị) bấm ⚡, chọn gang rồi đặt:
- **Tự tắt sau khi bật**: gang BẬT được N giây/phút/giờ (1 giây – 24 giờ) thì tự TẮT.
- **Tự bật lại sau khi tắt**: gang TẮT được N thì tự BẬT lại.
- **Đồng kích hoạt**: khi một gang khác (của thiết bị khác hoặc cùng thiết bị) chuyển sang bật/tắt thì gang này bật/tắt theo (chọn cả điều kiện và kết quả).

Luật chạy trong backend (`backend/src/rules.rs`): mỗi bản tin trạng thái từ gateway được so với trạng thái cũ; chuyển ON↔OFF sẽ hẹn giờ (bảng `pending_actions`, sống sót qua khởi động lại backend, kiểm tra mỗi giây) hoặc kích hoạt luật `link`. Áp dụng cho mọi cách đổi trạng thái (app, ngữ cảnh, công tắc vật lý). Hẹn giờ bị huỷ nếu gang đổi trạng thái trước hạn; mỗi gang tối đa một luật tự tắt và một luật tự bật lại; luật `link` **không nối chuỗi** (gang bị luật điều khiển không kích hoạt luật khác) để tránh vòng lặp. Cần backend và gateway online; hẹn giờ đến hạn mà gateway offline quá 60 giây thì bỏ. Chỉ áp dụng cho trạng thái ON/OFF — rèm (OPEN/CLOSE) chưa hỗ trợ.

## Thông báo giọng nói qua loa Google Cast

Menu ⋮ → **Loa thông báo** (quản trị): "Thêm loa" quét mạng LAN của bộ điều khiển trung tâm (mDNS `_googlecast._tcp`) và liệt kê Google Home / Nest Mini… tìm thấy; chọn loa, đặt tên, bấm ▶ để phát thử. Trong form ngữ cảnh và trong màn ⚡ của từng luật có mục **Thông báo qua loa**: chọn loa và (tuỳ chọn) câu đọc; để trống câu thì dùng câu tự sinh ("Đã chuyển sang chế độ X", "Mọi người đã rời nhà. Đã chuyển sang chế độ X", "Đã tự động tắt <thiết bị>", "<thiết bị> đã bật theo <thiết bị khác>"). **Chỉ đọc khi hành động TỰ chạy** (ngữ cảnh theo giờ / khi rời nhà, luật ⚡), không đọc khi bạn bấm chạy tay.

- Loa Google Home/Nest Mini dùng **Google Cast**, không phải thiết bị Matter (Matter chỉ để Google Home điều khiển công tắc); vì vậy loa được thêm qua Cast chứ không qua Matter bridge.
- **Phải có gateway chạy trong cùng mạng LAN với loa.** Backend/gateway chạy trên máy chủ đám mây (như 10.60.1.14) không thấy được loa trong nhà (không có mDNS tới LAN đó). Nếu backend ở xa: chạy thêm một gateway chỉ-làm-loa trên máy Linux trong nhà bằng `edge/docker-compose.cast.yml` (cần token gateway mới tạo trong app, `MQTT_DISABLED=1`, không cần Zigbee2MQTT). Gateway tự khai báo `hello {caps}`; backend chọn gateway Zigbee/Matter cho thiết bị và chỉ chọn gateway có `cast` cho loa. Mỗi loa nhớ gateway đã tìm thấy nó (`speakers.gateway_id`), gateway đó offline thì không phát (không phát nhầm qua gateway khác).
- **Loa giả lập để thử không cần loa thật:** profile `cast-sim` (`infra/cast-sim`) chạy một loa Cast giả (mDNS + CASTV2) kèm giao diện web ở cổng 8082 (danh sách thông báo đã "phát", nghe lại ngay trên trình duyệt, nhật ký phiên Cast) và một gateway chỉ-làm-loa (`gateway-cast`, cần `CAST_GATEWAY_TOKEN` là token của một gateway tạo trong app): `COMPOSE_PROFILES=sim,cast-sim CAST_GATEWAY_TOKEN=… docker compose up -d --build`. Trên server (đã làm): giao diện ở cổng 18082, gateway tên "Loa giả lập (cast-sim)". Loa giả lập chỉ kiểm tra luồng backend → gateway → Cast, không chứng minh tương thích với loa Google thật.
- Luồng: backend quyết định "nói gì, loa nào" → gửi `speak` xuống gateway (Pi cùng LAN với loa) → gateway tải mp3 TTS tiếng Việt → phục vụ qua HTTP cổng `CAST_HTTP_PORT` (mặc định 8765) → cast tới loa (CASTV2/TLS cổng 8009, Default Media Receiver) → gửi STOP khi xong. Backend ở datacenter không với tới loa trong LAN nên không tự cast. Gateway cần `network_mode: host` (đã có trong `edge/docker-compose.yml`) và loa phải truy cập được cổng HTTP của Pi (kiểm tra tường lửa/isolation Wi‑Fi).
- **TTS dùng endpoint Google Translate không chính thức** (`translate.google.com/translate_tts`): không có tài liệu, có thể bị đổi hoặc chặn bất cứ lúc nào, và dùng ngoài trình duyệt có thể trái điều khoản dịch vụ của Google. Đổi nguồn bằng biến `TTS_URL_TEMPLATE` của gateway (đặt `{text}` là chỗ chèn câu đã mã hoá URL), ví dụ trỏ tới dịch vụ TTS riêng hoặc Google Cloud Text-to-Speech qua một proxy nhỏ.
- Mỗi loa đọc từng câu một (xếp hàng); khi đọc, loa tạm dừng nhạc đang phát. Câu tối đa 140 ký tự.

## Addon trong nhà (camera, máy lọc nước, …)

Mọi thiết bị không đi qua Zigbee dùng **một addon duy nhất**: [`addons/msmart`](addons/msmart) (image `smarthome-addon`, project compose `msmart-addon`), chạy cạnh [go2rtc](https://github.com/AlexxIT/go2rtc) trên một máy Linux trong nhà (Pi, NAS, mini PC), kết nối ra cloud bằng **một** token gateway riêng. Không cần Zigbee.

- Mỗi loại thiết bị là một module trong `addons/msmart/src/` (`camera/`, `purifier/`), khai báo một khả năng trong `hello.caps`; backend định tuyến lệnh theo khả năng đó. Bật/tắt bằng `ADDON_DEVICES` (mặc định `camera,purifier`).
- **Thêm loại thiết bị mới**: tạo module (`load` / `run` / `on_connect` / `handle`), thêm một trường vào `Hub`, một khả năng trong `caps()` và một nhánh trong `dispatch()` ở `src/main.rs`; thiết bị dạng cảm biến/công tắc nên gửi `devices` / `state` / `availability` và nhận `set` như gateway Zigbee để backend, app, Google Home dùng lại đường xử lý sẵn có (xem máy lọc nước).
- Dữ liệu tại chỗ ở volume `msmart-addon_addon-data` (`/data`): `cameras.json` (có mật khẩu camera), `purifiers.json`, … Sao lưu volume này.

Triển khai trên máy trong nhà ([`edge/docker-compose.addon.yml`](edge/docker-compose.addon.yml), cần `network_mode: host`): ghi `CLOUD_WS_URL` và `GATEWAY_TOKEN` vào `edge/.env.addon` (chmod 600), rồi

```bash
cd edge && docker compose --env-file .env.addon -f docker-compose.addon.yml up -d --build
```

Hoặc từ máy dev: `edge/deploy-pi.sh pi@<ip-pi> --addon`. Lần đầu từ bản cũ (project `smarthome-camera`), script tự đổi `.env.camera` → `.env.addon`, chép dữ liệu sang volume mới (giữ volume cũ để dự phòng) và gỡ project cũ.

### Camera Wi‑Fi

- **Thêm camera**: app → ⋮ → Camera → **+**. Bấm "Tìm camera trong mạng" (ONVIF WS-Discovery) hoặc nhập IP + cổng ONVIF; camera không có ONVIF thì nhập URL RTSP (không có PTZ/cảnh báo). Addon thử kết nối thật trước khi lưu: sai mật khẩu, sai địa chỉ, chưa bật ONVIF đều báo lỗi rõ.
- **Mật khẩu camera chỉ nằm ở addon** (`/data/cameras.json`, quyền 600). Cloud chỉ lưu tên, phòng, địa chỉ hiển thị, hãng/model và khả năng (PTZ, sự kiện). Mất volume dữ liệu addon = phải thêm lại camera.
- **Xem trực tiếp**: WebRTC đi thẳng điện thoại ↔ go2rtc; máy chủ chỉ chuyển SDP offer/answer. Không nối được trong ~8 giây (NAT đối xứng, một số mạng 4G) thì app chuyển sang **ảnh chụp ~1 giây/lần qua máy chủ**. Chuyển tiếp cổng 8555 (UDP+TCP) trên router về máy chạy addon giúp nối thẳng ổn định hơn.
- **PTZ**: giữ nút mũi tên / zoom để quay, thả ra để dừng (ONVIF ContinuousMove + Stop, camera tự dừng sau 2 giây nếu lệnh dừng bị lạc). go2rtc không có PTZ nên addon tự gọi ONVIF.
- **Cảnh báo chuyển động**: addon đăng ký sự kiện ONVIF (PullPoint), mỗi lần chuyển từ "không" sang "có chuyển động" thì cloud lưu thông báo, đẩy realtime + FCM; tối đa 1 lần/phút mỗi camera, bật/tắt theo từng camera. Chạm thông báo để mở camera.
- Quyền: thành viên trở lên xem/PTZ; chỉ quản trị thêm/sửa/xoá. Khách thuê và khách xem không thấy camera.

Chạy thử với **camera ONVIF giả lập** (PTZ + sự kiện + video test, không cần camera thật): tạo gateway trong app (đặt tên "Addon"), rồi

```bash
COMPOSE_PROFILES=sim,camera ADDON_GATEWAY_TOKEN=<token> docker compose up -d --build
```

Trang camera giả: http://localhost:8090 (tài khoản `admin` / `camera-sim-pass`, bấm "Mô phỏng chuyển động"). Trong app thêm camera địa chỉ `camera-sim`, cổng `8000`.

### Máy lọc nước Karofi (Bluetooth)

Addon đọc máy lọc nước Karofi có Bluetooth (bộ điều khiển Makipos, tên quảng bá `TCM-*`) — cùng container, cùng token, khả năng `purifier`. Giao thức viết lại từ tích hợp Home Assistant mã nguồn mở [luuquangvu/karofi](https://github.com/luuquangvu/karofi) (do cộng đồng tìm hiểu, Karofi không công bố; model khác/firmware mới có thể báo khác). Chưa kiểm thử với máy lọc thật trong repo này.

- **Thêm máy**: app → **+** → Máy lọc nước → addon quét Bluetooth ~8 giây → chọn máy, đặt tên/phòng. Addon phải kết nối và đọc được số liệu thật thì mới lưu (`/data/purifiers.json`, chỉ có địa chỉ MAC).
- Trên cloud, máy lọc là một **thiết bị bình thường** (`devices.kind = 'purifier'`, `ieee_address` = MAC): addon gửi `devices` / `state` / `availability` như gateway Zigbee. Trạng thái: `tds` (ppm), `quality` (good < 50 · fair ≤ 150 · poor), `filters[]` (`percent` = mức thấp hơn giữa theo lịch `iro_lTime/iro_hsd` và theo giờ chạy `iro_rtr/iro_rtt`, `days_left`, `hours_left`…), `filter_min`, `errors[]`, và `hydrogen` / `water_mode` với máy có.
- **Đọc định kỳ** mỗi `PURIFIER_POLL_SECS` (mặc định 60 s): kết nối, đọc các đặc tính của dịch vụ `12ac`, gửi `{"et":"NP"}` vào `ab02` và nghe notify `ac02`, rồi ngắt. Chỉ gửi trạng thái lên cloud khi có thay đổi. 3 lần đọc hỏng liên tiếp → offline.
- **Đã thay lõi**: màn máy lọc → nút đặt lại trên lõi → `POST /v1/devices/:id/command {"payload":{"reset_filter":n}}` (thành viên trở lên) → addon ghi `\x01{"et":"CP","pc":"iro_rsft","d":n-1}\x04`.
- **Cảnh báo** (gửi cả căn hộ, không phụ thuộc ngữ cảnh): máy báo mã lỗi mới (1 bơm chạy quá 5 giờ, 2 nước vào yếu, 4 không có nước, 5 rò nước, 100 TDS cao) và lõi lọc xuống ≤ 10%.
- **Google Home**: `SENSOR` + `SensorState` — `FilterLifeTime` (% lõi thấp nhất) và `WaterLeak` (mã lỗi 5). Google không có thuộc tính TDS.
- Gỡ máy: màn máy lọc → ⋮ → Gỡ (`DELETE /v1/devices/:id`, chỉ áp dụng cho máy lọc).

Máy chạy addon cần **BlueZ** và Bluetooth không bị chặn, container mount `/run/dbus` (đã có trong `edge/docker-compose.addon.yml`). Trên Raspberry Pi OS nếu `bluetoothctl show` báo `PowerState: off-blocked`: `sudo rfkill unblock bluetooth`. Addon chạy bằng user `nobody` (65534): dbus-daemon của máy chủ từ chối uid không có trong `/etc/passwd` của máy chủ (uid 10001 của image). Volume dữ liệu tạo từ bản cũ thì chown một lần: `docker run --rm -v msmart-addon_addon-data:/data debian:bookworm-slim chown -R 65534:65534 /data`. Đặt máy chạy addon trong tầm ~10 m của máy lọc. Bluetooth và Wi‑Fi trên Pi dùng chung chip; đọc mỗi phút một lần là nhẹ.

## Chạy với Zigbee2MQTT thật trên Pi 3

1. Cắm dongle, tìm đường dẫn ổn định: `ls /dev/serial/by-id/`.
2. Sonoff ZBDongle-E đã cấu hình `adapter: ember`; cần firmware **coordinator** EmberZNet ≥ 7.4.x (xem ghi chú trong `infra/zigbee2mqtt/configuration.yaml`). Đặt `network_key`/`pan_id`/`ext_pan_id` ngẫu nhiên.
3. Trên Pi: `cd edge && cp .env.example .env` → điền `CLOUD_WS_URL` (dạng `wss://api.<domain>/gw/ws`), `GATEWAY_TOKEN`, `ZIGBEE_DEVICE` → `./gen-secrets.sh` (sinh mật khẩu MQTT ngẫu nhiên vào `.env`; Mosquitto không cho kết nối ẩn danh) → `docker compose up -d`.
   Không build trên Pi: từ máy dev chạy `edge/deploy-pi.sh pi@<ip-pi>` (build image `linux/arm64`, chép qua SSH, `docker compose up -d --no-build` trên Pi; thêm `--addon` cho addon trong nhà, `--no-up` để chỉ chép). Cần SSH bằng khoá; script không ghi đè `.env` và `configuration.yaml` của Z2M trên Pi.
4. Ghép thiết bị: trong app, mở căn hộ → nút **+** (Thêm thiết bị) trên thanh tiêu đề (quản trị căn hộ), rồi reset công tắc theo hướng dẫn của hãng. App bật *Permit join* qua gateway (tối đa 254 giây, đóng popup là tắt), hiện thiết bị vừa vào mạng và cho đặt tên/chọn phòng ngay. Z2M frontend `http://<ip-pi>:8081` vẫn dùng được khi cần.

### Giảm ghi thẻ nhớ trên Pi

Thẻ SD hỏng chủ yếu do ghi liên tục (log, dữ liệu cache). Cấu hình trong repo đã giảm sẵn:

| Thành phần | Thay đổi | Đánh đổi |
|---|---|---|
| Docker (mọi file `edge/docker-compose*.yml`) | `logging: none`, `/tmp` của container là tmpfs (RAM) | `docker logs` trống. Gỡ lỗi tạm: `DOCKER_LOG_DRIVER=local docker compose up -d <service>`, xong chạy lại `docker compose up -d` |
| Mosquitto | `autosave_interval 0`: chỉ lưu bản tin retained khi broker dừng; log chỉ error/warning ra stdout | Broker chết đột ngột → mất retained tới khi Z2M publish lại (`docker compose restart zigbee2mqtt` nếu thiếu thiết bị) |
| Zigbee2MQTT | `log_output: [console]` (không ghi file log), `log_level: warning`, `cache_state_persistent: false` | Sau khi Z2M khởi động lại, trạng thái trong Z2M trống tới khi thiết bị báo; backend vẫn giữ trạng thái |
| Gateway, addon trong nhà | `RUST_LOG=warn`, chỉ ra stdout | — |

Vẫn phải ghi (ít, chỉ khi có thay đổi): `database.db`/`coordinator_backup.json`/cấu hình của Z2M, dữ liệu ghép nối Matter (`matterbridge-data`), danh sách camera và máy lọc nước của addon. Đây là dữ liệu cần giữ, nên sao lưu.

Mức hệ điều hành (chạy một lần): `sudo ./edge/pi-reduce-writes.sh` — journald chỉ giữ log trong RAM, tắt rsyslog nếu có, đặt Docker mặc định không lưu log (khi chưa có `/etc/docker/daemon.json`), kiểm tra `noatime` và `/tmp`. Thêm `--no-swap` để tắt swap trên thẻ (Pi 3 chỉ có 1 GB RAM, xem `free -m` trước). Khởi động lại Pi sau khi chạy.

`GATEWAY_TOKEN` lấy trong app: vào căn hộ → biểu tượng router (**Bộ điều khiển trung tâm**) → **Thêm** → app hiện `CLOUD_WS_URL` và `GATEWAY_TOKEN` (chỉ hiện một lần; chỉ admin/owner). Hoặc gọi `POST /v1/homes/:home_id/gateways`; script bootstrap làm sẵn cho dev.

## Đăng nhập bằng Google / Apple

Song song với email + mật khẩu. App lấy **ID token** từ Google/Apple, gửi `POST /v1/auth/sso {provider, id_token, nonce?, name?}`; backend tự kiểm tra chữ ký (JWKS của Google/Apple), `iss`, `aud` ∈ client ID đã cấu hình, hạn dùng, `nonce`, rồi cấp phiên MSmart như đăng nhập thường (`backend/src/sso.rs`). `GET /v1/auth/providers` cho app biết nút nào bật.

Gắn tài khoản:
1. Đã từng đăng nhập bằng cùng Google/Apple (`sub`) → đúng tài khoản đó.
2. Email **đã được Google/Apple xác minh** trùng tài khoản email/mật khẩu có sẵn → gộp vào tài khoản đó, **xoá mật khẩu cũ và đăng xuất mọi phiên cũ** (đăng ký bằng email không xác minh email, nên mật khẩu cũ có thể do người khác đặt). Từ đó tài khoản chỉ đăng nhập bằng Google/Apple.
3. Còn lại → tài khoản mới không có mật khẩu. Apple ẩn email thì dùng địa chỉ chuyển tiếp `@privaterelay.appleid.com`; không có email/chưa xác minh/email đã thuộc tài khoản khác thì email nội bộ `…@users.msmart.invalid`.

Trang liên kết Google Home (`/oauth/authorize`) cũng có nút Google/Apple (Google Identity Services, Sign in with Apple JS) để tài khoản không có mật khẩu vẫn liên kết được; ID token phải mang đúng nonce của trang (nằm trong chữ ký form).

Cấu hình (bạn tự tạo, không phải bí mật):

| Ở đâu | Tạo gì | Đặt vào |
|---|---|---|
| Google Cloud Console (dự án `msmart-ed122`) → Credentials | OAuth client **iOS** (bundle `com.newmoon22.msmart`) | app: `--dart-define=GOOGLE_IOS_CLIENT_ID=…`; `app/ios/Flutter/GoogleSignIn.xcconfig`: `GOOGLE_REVERSED_CLIENT_ID` (client iOS đảo ngược); backend: `GOOGLE_SIGNIN_CLIENT_IDS` |
| | OAuth client **Web**, Authorized JavaScript origins: `https://msmart-api.newmoon.cloud` | app: `--dart-define=GOOGLE_SERVER_CLIENT_ID=…` (bắt buộc trên Android); backend: `GOOGLE_SIGNIN_WEB_CLIENT_ID` |
| | OAuth client **Android** (package `com.newmoon22.msmart` + SHA‑1 khoá ký) | chỉ cần tồn tại, không đặt vào đâu |
| Apple Developer → Identifiers | Bật **Sign in with Apple** cho App ID `com.newmoon22.msmart` | backend: `APPLE_SIGNIN_CLIENT_IDS=com.newmoon22.msmart` (app đã có entitlement) |
| | **Services ID** (vd `com.newmoon22.msmart.web`), domain `msmart-api.newmoon.cloud`, return URL `https://msmart-api.newmoon.cloud/oauth/authorize` | backend: `APPLE_SIGNIN_WEB_SERVICE_ID` |

**Xoá tài khoản** (App Store Guideline 5.1.1(v)): app → biểu tượng tài khoản ở màn danh sách căn hộ → *Xoá tài khoản*. `GET /v1/me/deletion` cho biết căn hộ nào bị xoá theo (tenant mà người dùng là quản lý duy nhất: xoá cả căn hộ, thiết bị, gateway); `DELETE /v1/me {"confirm":"DELETE"}` xoá, rồi thu hồi refresh token Sign in with Apple (backend lấy token này lúc đăng nhập Apple từ `authorizationCode`, cần `APPLE_TEAM_ID`, `APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_KEY_FILE`) và xoá người dùng khỏi Google HomeGraph.

App chỉ hiện nút Apple trên iOS. App cần Flutter ≥ 3.47 (google_sign_in_ios 6.4 dùng GoogleSignIn 10, tương thích Firebase 13).

## Google Home cloud-to-cloud: máy chủ OAuth 2.0 (liên kết tài khoản)

Backend có sẵn máy chủ OAuth 2.0 (authorization code flow) để người dùng liên kết tài khoản MSmart trong ứng dụng Google Home, theo [yêu cầu của Google](https://developers.home.google.com/cloud-to-cloud/project/authorization). Gồm phần xác thực (OAuth) và fulfillment (`POST /google/fulfillment`).

| Endpoint | Việc |
|---|---|
| `GET /oauth/authorize` | Trang đăng nhập + đồng ý (HTML, tiếng Việt). Kiểm tra `client_id`, `redirect_uri` (chỉ nhận `https://oauth-redirect.googleusercontent.com/r/<GOOGLE_PROJECT_ID>` và bản `-sandbox`), `response_type=code` |
| `POST /oauth/authorize` | Kiểm tra email/mật khẩu (chung giới hạn tốc độ với đăng nhập app) → 303 về `redirect_uri?code=…&state=…` |
| `POST /oauth/token` | `grant_type=authorization_code` → `access_token` (1 giờ) + `refresh_token`; `grant_type=refresh_token` → `access_token` mới. Client id/secret trong body hoặc HTTP Basic |

- Mã ủy quyền dùng một lần, sống 10 phút, gắn với người dùng + client + `redirect_uri`. Mã bị dùng lại → thu hồi luôn liên kết đã cấp từ mã đó.
- Refresh token không hết hạn và **không xoay vòng** (Google khuyến nghị để tránh tự huỷ liên kết). Lỗi mã/refresh token trả `400 {"error":"invalid_grant"}`; sai client trả `401 invalid_client`.
- Mọi mã/token chỉ lưu dạng băm SHA-256 (`oauth_codes`, `oauth_grants`, `oauth_tokens`). Form đăng nhập có chữ ký HMAC trên các tham số của Google (không sửa được `redirect_uri` giữa chừng) và từ chối gửi từ trang khác (`Origin`). Trang cấm nhúng khung, không cache.
- Fulfillment `POST /google/fulfillment` (xác thực bằng `Authorization: Bearer <access_token>`, extractor `oauth::OAuthUser`):
  - **SYNC**: thiết bị ở mọi căn hộ người dùng là thành viên trở lên (khách thuê/khách xem không đưa sang Google). Mỗi gang công tắc là một thiết bị Google (id `<uuid>:<khoá gang>`), tên lấy theo tên gang đặt trong app, loại theo loại tải: Đèn → `LIGHT`, Quạt → `FAN`, Ổ cắm → `OUTLET`, còn lại `SWITCH` (trait `OnOff`; bóng đèn có độ sáng thêm `Brightness`). Rèm → `CURTAIN` (`OpenClose`). Cảm biến nhiệt độ/độ ẩm → `SENSOR` chỉ đọc. Phòng → `roomHint`.
  - **QUERY**: trạng thái từ DB (`on`, `openPercent`, `brightness`, nhiệt độ/độ ẩm); thiết bị hoặc gateway offline → `OFFLINE`.
  - **EXECUTE**: `OnOff`, `BrightnessAbsolute`, `OpenClose` → lệnh Zigbee2MQTT qua gateway (cùng kiểm tra lệnh và `command_log` như app); gateway offline → `OFFLINE / deviceOffline`; lệnh không hỗ trợ → `functionNotSupported`.
  - **DISCONNECT**: thu hồi luôn liên kết (refresh + access token).
- **Report State + Request Sync** qua Google HomeGraph API (bật khi đặt `GOOGLE_HOMEGRAPH_SA_FILE`; khi bật, SYNC khai báo `willReportState: true`):
  - Trạng thái thiết bị đổi (bấm trong app, bấm công tắc thật, rèm chạy, thiết bị online/offline) → `devices:reportStateAndNotification` cho mọi người đang liên kết Google có quyền với căn hộ. Chỉ gửi phần thật sự đổi so với lần báo trước.
  - Danh sách thiết bị đổi (ghép/xoá thiết bị, đổi tên, đổi phòng hay loại tải, đổi tên/xoá phòng, xoá gateway) → `devices:requestSync`, gom các thay đổi trong 3 giây và chỉ gửi khi nội dung SYNC thật sự khác lần trước.
  - Service account: Google Cloud Console của dự án Google Home → bật **HomeGraph API** → tạo service account (vai trò cấp theo hướng dẫn Report State của Google — chưa đối chiếu lại trong lần làm này) → tạo khoá JSON, đặt vào `./secrets/` trên server và `GOOGLE_HOMEGRAPH_SA_FILE=/run/secrets/<file>.json`. Dùng chung đoạn lấy token với FCM (`gsa.rs`).
- Chưa làm: cảm biến cửa/hiện diện chưa đưa sang Google; đổi quyền thành viên (vd hạ xuống khách) chưa tự Request Sync.

**Cấu hình** (biến môi trường của backend, file `.env` trên server, chmod 600):

```bash
GOOGLE_OAUTH_CLIENT_ID=google-home        # tự đặt
GOOGLE_OAUTH_CLIENT_SECRET=$(openssl rand -hex 32)
GOOGLE_PROJECT_ID=<project id trong Google Home Developer Console>
```

Trong Google Home Developer Console → dự án cloud-to-cloud → **Account linking**: Client ID và Client secret như trên, Authorization URL `https://<domain>/oauth/authorize`, Token URL `https://<domain>/oauth/token`; phần **Cloud fulfillment URL**: `https://<domain>/google/fulfillment`. Google bắt buộc **HTTPS** cho cả hai URL, nên backend phải có tên miền + chứng chỉ (vd qua Cloudflare Tunnel hoặc reverse proxy).

## Kết nối Google Home / Apple Home (Matter)

App có thể tạo mã QR để ghép toàn bộ thiết bị với **Google Home / Apple Home** (và Alexa, SmartThings) qua chuẩn **Matter**.

```
Home app (điện thoại)  ──LAN/mDNS──▶  Matterbridge (Pi, host network)  ◀──MQTT──  Zigbee2MQTT
                                            ▲ WebSocket cục bộ
Flutter app ── backend (cloud) ◀── gateway agent ┘   (lấy mã QR, mở/đóng ghép nối, ngắt ứng dụng)
```

- Matter điều khiển **trong mạng LAN nhà**, nên bridge chạy trên Pi (`infra/matterbridge`, dựa trên [Matterbridge](https://github.com/Luligu/matterbridge) + plugin `matterbridge-zigbee2mqtt`), không chạy trên cloud.
- Trong app: vào căn hộ → biểu tượng **QR** (chỉ admin/owner) → quét mã bằng Home app (Apple Home: *+ → Thêm phụ kiện*; Google Home: *+ → Thiết lập thiết bị → thiết bị tương thích Matter*).
- **Google Home cần một thiết bị trung tâm Matter của Google trong nhà** (loa/màn hình Nest hoặc Google TV tương thích Matter, cùng mạng với Pi và điện thoại). Thiếu nó, Google Home báo "Bạn cần có một thiết bị trung tâm chuẩn Matter". Danh sách model được hỗ trợ lấy từ tài liệu Google Home (mình chưa kiểm chứng được danh sách này trong repo). Apple Home cần Apple TV/HomePod để điều khiển khi ra ngoài.
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
| `GET/POST /v1/homes/:id/scenes`, `PATCH/DELETE /v1/scenes/:id`, `POST /v1/scenes/:id/run` | ngữ cảnh (scene): xem = guest, chạy = member, tạo/sửa/xoá = admin. Body: `name`, `icon`, `actions:[{device_id,payload}]`, tự kích hoạt `auto_enabled`, `auto_time` ("HH:MM"), `auto_time_end` ("HH:MM" hoặc "" để bỏ), `auto_days` (1 = T2 … 7 = CN), `auto_leave`, `auto_arrive`, `trigger_sensors:[{device_id,event}]` (event: `occupied` / `vacant` / `open` / `closed`), `trigger_logic` (`any` / `all`), giãn cách `step_delay_ms` (0–10000, 0 = cùng lúc). `run` với ngữ cảnh giãn cách trả ngay `{"status":"running"}` |
| `POST /v1/auth/refresh`, `/v1/auth/logout`, `/v1/auth/logout-all` | làm mới (xoay vòng), đăng xuất thiết bị, đăng xuất mọi thiết bị; đăng nhập/đăng ký/làm mới có giới hạn tốc độ (`429` + `Retry-After`) |
| `POST /v1/tenants`, `POST /v1/tenants/:tid/homes`, `GET /v1/homes` | khách hàng, căn hộ |
| `GET/POST /v1/homes/:id/rooms`, `PATCH/DELETE /v1/rooms/:id` | phòng: tên + icon (`living` `bedroom` `kitchen` `bathroom` `dining` `office` `balcony` `garage` `kids` `laundry` `hallway` `other`) |
| `GET /v1/homes/:id/devices`, `PATCH /v1/devices/:id` | thiết bị: đổi tên, gán phòng, đặt tên + loại tải cho từng gang (`channels`: `light` `fan` `outlet` `air_conditioner` `water_heater` `other`) |
| `POST /v1/devices/:id/command` `{"payload":{"state_1":"TOGGLE"}}` | điều khiển → `202`; `503` nếu gateway offline |
| `GET /v1/homes/:id/ws?token=` | realtime: `device_state`, `device_online`, `gateway`, `devices_changed`, `scene_active`, `alert` (`alert` chỉ gửi cho thành viên trở lên) |
| `GET/POST /v1/homes/:id/speakers`, `POST …/speakers/scan`, `PATCH/DELETE /v1/speakers/:id`, `POST /v1/speakers/:id/test` | loa Cast: xem = member; quét/thêm/đổi tên/xoá = admin; phát thử = member. Ngữ cảnh và luật nhận thêm `speaker_ids`, `speak_text` |
| `GET/POST /v1/homes/:id/rules`, `PATCH/DELETE /v1/rules/:id` | luật thiết bị `{device_id,key,kind: auto_off\|auto_on\|link, delay_s, source_device_id, source_key, source_state, target_state}`: xem = member, sửa = admin |
| `PUT/DELETE /v1/homes/:id/location`, `PUT /v1/homes/:id/presence` | vị trí căn hộ `{lat,lng,radius_m}` (admin); điện thoại báo `{inside: bool}` (member) cho "tự chuyển khi rời nhà" |
| `GET /v1/homes/:id/notifications`, `DELETE /v1/homes/:id/active-scene`, `POST/DELETE /v1/push/tokens` | lịch sử cảnh báo (member); tắt ngữ cảnh đang bật (member); đăng ký/gỡ token FCM của thiết bị `{token, platform: ios\|android}` |
| `GET/POST /v1/homes/:id/members…`, `/invites`, `/gateways` | thành viên, mời, gateway |
| `GET /v1/homes/:id/matter`, `POST …/matter/pairing` `{"open":bool}`, `DELETE …/matter/fabrics/:index` | Matter: trạng thái + mã QR (admin), mở/đóng ghép nối, ngắt một ứng dụng |
| `POST /v1/gateways/:id/rotate`, `DELETE /v1/gateways/:id` | thu hồi token gateway (giữ thiết bị) / xoá gateway (xoá cả thiết bị của nó) |

Lệnh chỉ chấp nhận thuộc tính `state*` (ON/OFF/TOGGLE), `brightness*`, `color_temp*`; mọi payload khác bị từ chối để client không thể gọi các topic quản trị của Zigbee2MQTT.

## Đã kiểm chứng / chưa kiểm chứng

Thông báo giọng nói: đã kiểm thử đầu-cuối trên Docker với **loa Cast giả** do tôi tự viết (quảng bá mDNS, TLS tự ký, CASTV2 tối thiểu): quét thấy loa, thêm loa qua app, gateway tải TTS (máy chủ TTS giả), phục vụ mp3 qua HTTP, loa giả nhận LOAD và tải được tệp, STOP sau khi phát; câu đúng cho ngữ cảnh theo giờ, rời nhà, luật tự tắt và luật đồng kích hoạt. **Chưa kiểm chứng**: với loa Google Home/Nest Mini thật (giao thức tôi viết theo hiểu biết về CASTV2, chưa đối chiếu với thiết bị thật), với Google Translate TTS thật từ gateway, và mDNS trên mạng LAN thật.

Luật thiết bị (⚡): đã kiểm thử đầu-cuối trên Docker với simulator Zigbee (tự tắt ~4 s, tự bật lại ~3 s, huỷ khi đổi trạng thái trước hạn, luật bị tắt không chạy, đồng kích hoạt bật/tắt, không nối chuỗi, phân quyền, validate) và giao diện iOS Simulator (tạo luật tự tắt). **Chưa kiểm chứng**: với thiết bị VSmart thật (độ trễ phản hồi trạng thái), luật link qua nhiều gateway, khởi động lại backend giữa lúc đang hẹn giờ.

"Tự chuyển khi rời nhà": API đã kiểm thử đầu-cuối trên Docker (2 thành viên, người cuối rời mới chạy, báo lặp, quyền, xoá vị trí) và form + xin quyền + đặt vị trí trên iOS Simulator; app build được trên iOS Simulator và Android (APK debug). **Chưa kiểm chứng**: geofence thật (vào/ra vùng), callback nền khi app tắt, quyền "Luôn luôn" trên Android, trên máy thật.

Cảnh báo cảm biến: đã kiểm thử đầu-cuối trên Docker cục bộ (chuyển trạng thái → thông báo trong DB + WebSocket, chống trùng 60 giây, lọc theo vai trò) và giao diện trên iOS Simulator (tạo ngữ cảnh có cảnh báo, hộp thoại quyền, chạy ngữ cảnh). **Chưa kiểm chứng**: gửi FCM thật (backend chưa có khoá service account; `push.rs` mới chỉ có test đơn vị cho thân tin), nhận đẩy trên iOS/Android thật khi app bị tắt, chạy app trên Android (mới build APK debug thành công). Đổi ID app sang `com.newmoon22.msmart` nên bản cài cũ (`vn.smarthome.smartHome`) là app khác.

Đã chạy thật trong Docker: build 3 image, migration, đồng bộ thiết bị từ simulator, bật/tắt qua Pi (gateway→MQTT→simulator→trạng thái về), 400 với payload sai, 404 với người ngoài, 403 khi guest điều khiển, mã mời dùng 1 lần, WebSocket realtime, 503 khi gateway offline. App Flutter: `flutter analyze` sạch, đã chạy trên iOS Simulator (đăng nhập, xem căn hộ, đăng xuất; chưa thử Android và thiết bị thật). Bảo mật: Mosquitto bắt buộc đăng nhập + ACL, giới hạn đăng nhập/đăng ký, refresh token xoay vòng (kiểm thử API và WebSocket hết hạn, xem `docs/ARCHITECTURE.md` §5). Thuộc tính thiết bị đã đối chiếu với tài liệu Zigbee2MQTT nhưng chưa thử với dongle và thiết bị VSmart thật, chưa deploy lên Cloudflare, test tự động mới có ở mức đơn vị (`cd backend && cargo test`, `cd app && flutter test --dart-define=API_URL=http://127.0.0.1:18080 test/api_refresh_test.dart`) — xem `docs/ARCHITECTURE.md` mục "Việc còn lại".
