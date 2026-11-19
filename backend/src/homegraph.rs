//! Google HomeGraph API: chủ động báo cho Google khi có thay đổi, thay vì đợi Google hỏi.
//!  * Report State (`devices:reportStateAndNotification`): trạng thái thiết bị vừa đổi (bật/tắt từ app, từ công tắc, rèm…),
//!    để Google Home hiện đúng ngay.
//!  * Request Sync (`devices:requestSync`): danh sách thiết bị đổi (thêm/xoá/đổi tên/đổi phòng/đổi loại tải) → Google gọi lại SYNC.
//! TUỲ CHỌN: bật khi đặt `GOOGLE_HOMEGRAPH_SA_FILE` (service account của dự án Google Home, quyền HomeGraph API).
//! Chỉ báo cho người dùng đang liên kết Google (grant OAuth còn hiệu lực) và có quyền thành viên trở lên với căn hộ.
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    time::Duration,
};

use dashmap::DashMap;
use serde_json::{json, Map, Value};
use uuid::Uuid;

use crate::{
    access::{self, Role},
    google,
    gsa::ServiceAccount,
    AppState,
};

pub struct HomeGraph {
    sa: ServiceAccount,
    base: String,
    /// Trạng thái đã báo gần nhất theo (người dùng, id thiết bị Google): không báo lại khi không đổi.
    last: DashMap<(Uuid, String), Value>,
    /// Dấu vân tay kết quả SYNC gần nhất theo người dùng: chỉ Request Sync khi danh sách thật sự đổi.
    sync_fp: DashMap<Uuid, u64>,
    /// Căn hộ đang chờ Request Sync (gom nhiều thay đổi liên tiếp thành một lần).
    pending: DashMap<Uuid, ()>,
}

impl HomeGraph {
    pub fn from_env() -> Option<HomeGraph> {
        let path = std::env::var("GOOGLE_HOMEGRAPH_SA_FILE").ok().filter(|p| !p.trim().is_empty())?;
        let sa = ServiceAccount::load(&path, "https://www.googleapis.com/auth/homegraph", "homegraph")?;
        // HOMEGRAPH_URL chỉ dùng khi thử nghiệm với máy chủ giả lập.
        let base = std::env::var("HOMEGRAPH_URL").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| "https://homegraph.googleapis.com".into());
        tracing::info!(project = %sa.project_id, "homegraph: Report State + Request Sync đã bật");
        Some(HomeGraph { sa, base, last: DashMap::new(), sync_fp: DashMap::new(), pending: DashMap::new() })
    }

    async fn post(&self, path: &str, body: &Value) -> anyhow::Result<()> {
        let token = self.sa.access_token().await?;
        let r = self.sa.http.post(format!("{}{path}", self.base)).bearer_auth(token).json(body).send().await?;
        let status = r.status();
        if status.is_success() {
            return Ok(());
        }
        let text = r.text().await.unwrap_or_default();
        anyhow::bail!("HTTP {status}: {}", text.chars().take(200).collect::<String>())
    }
}

/// Người dùng đang liên kết Google và có quyền thành viên trở lên với căn hộ.
async fn linked_users(st: &AppState, home: Uuid) -> Vec<Uuid> {
    let users: Vec<Uuid> = sqlx::query_scalar(
        "SELECT DISTINCT g.user_id FROM oauth_grants g JOIN homes h ON h.id = $1
          WHERE g.revoked_at IS NULL
            AND (EXISTS (SELECT 1 FROM home_members m WHERE m.home_id = h.id AND m.user_id = g.user_id)
              OR EXISTS (SELECT 1 FROM tenant_members t WHERE t.tenant_id = h.tenant_id AND t.user_id = g.user_id))",
    )
    .bind(home)
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();
    let mut out = Vec::new();
    for u in users {
        if access::home_role(&st.db, u, home).await.is_ok_and(|r| r >= Role::Member) {
            out.push(u);
        }
    }
    out
}

/// Trạng thái để báo: như QUERY nhưng bỏ trường chỉ dành cho phản hồi QUERY.
fn report_state(mut v: Value) -> Value {
    if let Some(o) = v.as_object_mut() {
        o.remove("status");
        o.remove("errorCode");
    }
    v
}

/// Gọi khi trạng thái hoặc online của một thiết bị đổi (chạy nền, không chặn luồng gateway).
pub fn device_changed(st: &AppState, home: Uuid, device: Uuid) {
    if st.homegraph.is_none() {
        return;
    }
    let st = st.clone();
    tokio::spawn(async move {
        if let Err(e) = report_device(&st, home, device).await {
            tracing::warn!(%home, %device, "homegraph report state: {e:#}");
        }
    });
}

async fn report_device(st: &AppState, home: Uuid, device: Uuid) -> anyhow::Result<()> {
    let Some(hg) = st.homegraph.as_ref() else { return Ok(()) };
    let users = linked_users(st, home).await;
    if users.is_empty() {
        return Ok(());
    }
    let rows = google::home_rows(st, home, Some(&[device])).await.map_err(|e| anyhow::anyhow!("load device: {e:?}"))?;
    let Some(d) = rows.first() else { return Ok(()) };
    let online = d.online && st.hub.gateway_connected(d.gateway_id);
    let states: Vec<(String, Value)> = google::sync_devices(d, true)
        .iter()
        .filter_map(|g| g["id"].as_str().map(str::to_string))
        .map(|id| {
            let key = id.split_once(':').map(|(_, k)| k.to_string());
            let s = report_state(google::query_state(d, key.as_deref(), online));
            (id, s)
        })
        .collect();
    for user in users {
        let mut changed = Map::new();
        for (id, s) in &states {
            let k = (user, id.clone());
            if hg.last.get(&k).is_some_and(|old| *old == *s) {
                continue;
            }
            changed.insert(id.clone(), s.clone());
        }
        if changed.is_empty() {
            continue;
        }
        let body = json!({
            "requestId": Uuid::new_v4().to_string(),
            "agentUserId": user.to_string(),
            "payload": {"devices": {"states": Value::Object(changed.clone())}},
        });
        match hg.post("/v1/devices:reportStateAndNotification", &body).await {
            Ok(()) => {
                for (id, s) in changed {
                    hg.last.insert((user, id), s);
                }
            }
            // 404: Google chưa biết người dùng (chưa SYNC xong / đã huỷ liên kết) — không phải lỗi của mình.
            Err(e) if e.to_string().contains("404") => tracing::debug!(%user, "homegraph report state: agent not found"),
            Err(e) => tracing::warn!(%user, "homegraph report state: {e:#}"),
        }
    }
    Ok(())
}

/// Gọi khi danh sách/tên/phòng/loại thiết bị của căn hộ có thể đã đổi. Đợi 3 giây để gom các thay đổi liên tiếp,
/// rồi chỉ Request Sync cho người dùng có kết quả SYNC thật sự khác lần trước.
pub fn home_changed(st: &AppState, home: Uuid) {
    let Some(hg) = st.homegraph.as_ref() else { return };
    if hg.pending.insert(home, ()).is_some() {
        return; // đã có lần chờ cho căn hộ này
    }
    let st = st.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        let Some(hg) = st.homegraph.as_ref() else { return };
        hg.pending.remove(&home);
        for user in linked_users(&st, home).await {
            let devices = match google::sync_payload(&st, user).await {
                Ok(d) => d,
                Err(e) => {
                    tracing::warn!(%user, "homegraph sync fingerprint: {e:?}");
                    continue;
                }
            };
            let mut h = DefaultHasher::new();
            serde_json::to_string(&devices).unwrap_or_default().hash(&mut h);
            let fp = h.finish();
            if hg.sync_fp.insert(user, fp) == Some(fp) {
                continue;
            }
            match hg.post("/v1/devices:requestSync", &json!({"agentUserId": user.to_string(), "async": true})).await {
                Ok(()) => tracing::info!(%user, devices = devices.len(), "homegraph: request sync"),
                Err(e) if e.to_string().contains("404") => tracing::debug!(%user, "homegraph request sync: agent not found"),
                Err(e) => {
                    hg.sync_fp.remove(&user); // lần sau thử lại
                    tracing::warn!(%user, "homegraph request sync: {e:#}");
                }
            }
        }
    });
}

/// Google vừa SYNC (liên kết mới / người dùng yêu cầu đồng bộ): ghi nhận dấu vân tay để không Request Sync thừa.
pub fn synced(st: &AppState, user: Uuid, devices: &[Value]) {
    let Some(hg) = st.homegraph.as_ref() else { return };
    let mut h = DefaultHasher::new();
    serde_json::to_string(devices).unwrap_or_default().hash(&mut h);
    hg.sync_fp.insert(user, h.finish());
    hg.last.retain(|(u, _), _| *u != user); // báo lại trạng thái từ đầu cho các thiết bị Google vừa nhận
}
