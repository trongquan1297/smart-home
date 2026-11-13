// Gán kiểu Matter cho công tắc Zigbee2MQTT trước khi Matterbridge khởi động.
// Mặc định plugin đưa công tắc ra Matter dưới dạng "On/Off Light Switch" (kiểu thiết bị điều khiển, không phải tải),
// nhiều ứng dụng (Apple Home, Google Home) hiển thị/điều khiển tốt hơn khi nó là Light hoặc Outlet.
// Script đọc bản tin retained `<base>/bridge/devices`, lấy tên các thiết bị có expose `switch` và ghi vào
// lightList / outletList / switchList trong config plugin (giữ nguyên các mục người dùng đã thêm).
import { createRequire } from 'node:module';
import fs from 'node:fs';

const require = createRequire('/usr/local/lib/node_modules/matterbridge-zigbee2mqtt/package.json');
const mqtt = require('mqtt');
const [, , cfgPath, host, port, base, mode] = process.argv;
const lists = { light: 'lightList', outlet: 'outletList', switch: 'switchList' };
if (!lists[mode]) { console.log(`autolist: mode '${mode}' không hợp lệ, bỏ qua`); process.exit(0); }

const client = mqtt.connect(`${host}:${port}`, { connectTimeout: 5000, reconnectPeriod: 0, username: process.env.MQTT_USERNAME || undefined, password: process.env.MQTT_PASSWORD || undefined });
const done = (msg) => { console.log(`autolist: ${msg}`); try { client.end(true); } catch {} process.exit(0); };
setTimeout(() => done('không nhận được bridge/devices trong 10s, giữ nguyên danh sách'), 10000);
client.on('error', (e) => done(`lỗi MQTT ${e.message}, giữ nguyên danh sách`));
client.on('connect', () => client.subscribe(`${base}/bridge/devices`));
client.on('message', (_t, payload) => {
  let devices;
  try { devices = JSON.parse(payload.toString()); } catch { return done('bridge/devices không hợp lệ'); }
  const names = devices
    .filter((d) => d.type !== 'Coordinator' && d.definition && (d.definition.exposes ?? []).some((e) => e.type === 'switch'))
    .map((d) => d.friendly_name);
  const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
  for (const key of Object.values(lists)) cfg[key] = (cfg[key] ?? []).filter((n) => !names.includes(n));
  cfg[lists[mode]] = [...new Set([...(cfg[lists[mode]] ?? []), ...names])];
  fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2));
  done(`${names.length} công tắc được đưa ra Matter dạng '${mode}': ${names.join(', ') || '(không có)'}`);
});
