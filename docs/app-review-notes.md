# App Review Notes — MSmart (bản nháp trả lời Guideline 2.1)

Dán phần tiếng Anh dưới đây vào **App Store Connect → App Review Information → Notes**.
Thay các chỗ `<...>` trước khi gửi. Không commit mật khẩu thật vào repo.

---

```
Thank you for reviewing MSmart. Below is the information requested under Guideline 2.1.

1. SCREEN RECORDING
A screen recording captured on a physical iPhone running the latest iOS is attached / available at:
<link to recording>
It starts from app launch and shows: account registration (email), sign in with Apple and Google,
selecting a home, controlling devices (lights, switches, sensors), running a scene, inviting a member,
and deleting the account (Account icon at the top of the Homes screen → "Xoá tài khoản" = Delete account).
The app has no paid content, no in-app purchases and no public user-generated content
(device/room/scene names are private to members of the same home).

2. PURPOSE AND TARGET AUDIENCE
MSmart is a smart-home app for households in Vietnam. Users control Zigbee switches, lights and sensors,
Wi-Fi cameras and a water purifier in their home through a small home controller (Raspberry Pi gateway)
that connects to our cloud. It solves the problem of controlling devices from different vendors in one app,
with scenes, automations, presence-based automation (optional location), notifications and sharing the home
with family members.

3. HOW TO ACCESS THE MAIN FEATURES
Demo account (email sign-in on the login screen):
  Email: <reviewer email>
  Password: <reviewer password>
After signing in, open the home "LD22808". It contains 8 devices in 4 rooms and 3 scenes.
The devices in this demo home are served by a simulated home controller running on our server, because
the app requires physical Zigbee hardware installed in a home. They respond to commands exactly as real
devices do. The attached recording shows the app controlling real devices.
- Tap a device to turn it on/off; long-press a device to rename it or move it to another room.
- "Ngữ cảnh" (Scenes) tab: run "Về nhà", "Ra ngoài", "Đi ngủ".
- Members: invite/remove members of the home.
- Account deletion: Account icon on the Homes screen → "Xoá tài khoản", then type the confirmation word.
The location permission is optional and only used if the user enables "auto when leaving/arriving home".

4. EXTERNAL SERVICES
- Our own backend server (msmart-api.newmoon.cloud): accounts, homes, device control.
- Sign in with Apple and Google Sign-In: authentication.
- Firebase Cloud Messaging / Apple Push Notification service: push notifications.
- Google Home Graph (Google Home account linking, optional, cloud-to-cloud).
- Google STUN server (stun.l.google.com): establishing WebRTC connections for camera live view.
- <Text-to-speech service used for speaker announcements>
No analytics, advertising or AI services are used.

5. REGIONAL DIFFERENCES
The app's interface is in Vietnamese and is designed for the Vietnamese market. <Confirm: features work
the same in all regions where the app is available / app is distributed only in Vietnam.>

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
The app does not operate in a regulated industry and does not include protected third-party content.
```
