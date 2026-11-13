use axum::{
    extract::{ConnectInfo, Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, patch, post},
    Json, Router,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::FromRow;
use uuid::Uuid;

use crate::{
    access::{self, Role},
    auth::{self, AuthUser},
    automation, client_ws, gateway_ws,
    error::{ApiError, ApiResult},
    AppState,
};

pub fn router(st: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        // auth
        .route("/v1/auth/register", post(register))
        .route("/v1/auth/login", post(login))
        .route("/v1/auth/refresh", post(refresh))
        .route("/v1/auth/logout", post(logout))
        .route("/v1/auth/logout-all", post(logout_all))
        .route("/v1/me", get(me))
        // tenant / home
        .route("/v1/tenants", post(create_tenant))
        .route("/v1/tenants/:tid/homes", post(create_home))
        .route("/v1/homes", get(list_homes))
        // members & invites
        .route("/v1/homes/:hid/members", get(list_members))
        .route("/v1/homes/:hid/members/:uid", delete(remove_member))
        .route("/v1/homes/:hid/invites", post(create_invite))
        .route("/v1/invites/accept", post(accept_invite))
        // gateways
        .route("/v1/homes/:hid/gateways", get(list_gateways).post(create_gateway))
        .route("/v1/gateways/:gid", delete(delete_gateway))
        .route("/v1/gateways/:gid/rotate", post(rotate_gateway))
        // rooms
        .route("/v1/homes/:hid/rooms", get(list_rooms).post(create_room))
        .route("/v1/rooms/:rid", patch(update_room).delete(delete_room))
        // devices
        .route("/v1/homes/:hid/devices", get(list_devices))
        .route("/v1/devices/:did", patch(update_device))
        .route("/v1/devices/:did/command", post(command))
        // ngữ cảnh (scene), có thể tự kích hoạt theo khung giờ
        .route("/v1/homes/:hid/scenes", get(automation::list_scenes).post(automation::create_scene))
        .route("/v1/scenes/:sid", patch(automation::update_scene).delete(automation::delete_scene))
        .route("/v1/scenes/:sid/run", post(automation::run_scene))
        // Matter bridge (Google Home / Apple Home)
        .route("/v1/homes/:hid/matter", get(matter_info))
        .route("/v1/homes/:hid/matter/pairing", post(matter_pairing))
        .route("/v1/homes/:hid/matter/fabrics/:index", delete(matter_remove_fabric))
        // realtime
        .route("/v1/homes/:hid/ws", get(client_ws::handler))
        .route("/gw/ws", get(gateway_ws::handler))
        .with_state(st)
}

fn non_empty(s: &str, what: &str, max: usize) -> ApiResult<String> {
    let s = s.trim();
    if s.is_empty() || s.chars().count() > max {
        return Err(ApiError::BadRequest(format!("{what} must be 1..{max} chars")));
    }
    Ok(s.to_owned())
}

// ───────────────────────── auth ─────────────────────────

#[derive(Deserialize)]
struct RegisterReq {
    email: String,
    password: String,
    name: String,
}

// Giới hạn chống dò mật khẩu / spam tài khoản (cửa sổ trượt, trong RAM — xem ratelimit.rs).
const LOGIN_WINDOW: std::time::Duration = std::time::Duration::from_secs(15 * 60);
const LOGIN_FAIL_PER_IP: usize = 20;
const LOGIN_FAIL_PER_ACCOUNT: usize = 10;
const REGISTER_WINDOW: std::time::Duration = std::time::Duration::from_secs(3600);
const REGISTER_PER_IP: usize = 10;
const REFRESH_FAIL_PER_IP: usize = 30;

fn peer_ip(st: &AppState, headers: &HeaderMap, peer: std::net::SocketAddr) -> std::net::IpAddr {
    crate::ratelimit::client_ip(headers, peer, st.ip_header.as_ref())
}

async fn register(
    State(st): State<AppState>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    headers: HeaderMap,
    Json(b): Json<RegisterReq>,
) -> ApiResult<Json<Value>> {
    let ip = peer_ip(&st, &headers, peer);
    let rk = format!("reg:{ip}");
    st.limiter.check(&rk, REGISTER_PER_IP, REGISTER_WINDOW)?;
    st.limiter.record(&rk); // mọi lần đăng ký đều tính (kể cả lỗi): chặn spam tạo tài khoản

    let email = b.email.trim().to_lowercase();
    if !email.contains('@') || email.len() > 254 {
        return Err(ApiError::BadRequest("invalid email".into()));
    }
    if b.password.len() < 8 || b.password.len() > 128 {
        return Err(ApiError::BadRequest("password must be 8..128 chars".into()));
    }
    let name = non_empty(&b.name, "name", 100)?;
    let hash = auth::hash_password(b.password).await?;
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (email, password_hash, name) VALUES ($1,$2,$3) RETURNING id",
    )
    .bind(&email)
    .bind(hash)
    .bind(&name)
    .fetch_one(&st.db)
    .await?;
    let tokens = auth::start_session(&st, id).await?;
    Ok(Json(tokens.into_json(json!({ "id": id, "email": email, "name": name }))))
}

#[derive(Deserialize)]
struct LoginReq {
    email: String,
    password: String,
}

async fn login(
    State(st): State<AppState>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    headers: HeaderMap,
    Json(b): Json<LoginReq>,
) -> ApiResult<Json<Value>> {
    let ip = peer_ip(&st, &headers, peer);
    let email = b.email.trim().to_lowercase();
    if email.len() > 254 || b.password.len() > 256 {
        return Err(ApiError::Unauthorized);
    }
    let (ip_key, acct_key) = (format!("login-ip:{ip}"), format!("login-acct:{email}"));
    // Kiểm tra TRƯỚC khi băm mật khẩu: bị khoá thì không tốn CPU/RAM Argon2, và đúng mật khẩu cũng chưa vào được.
    st.limiter.check(&ip_key, LOGIN_FAIL_PER_IP, LOGIN_WINDOW)?;
    st.limiter.check(&acct_key, LOGIN_FAIL_PER_ACCOUNT, LOGIN_WINDOW)?;

    let row: Option<(Uuid, String, String, String)> =
        sqlx::query_as("SELECT id, password_hash, name, email FROM users WHERE lower(email) = lower($1)")
            .bind(&email)
            .fetch_optional(&st.db)
            .await?;
    let ok = match &row {
        Some((_, hash, _, _)) => auth::verify_password(b.password, hash.clone()).await,
        None => {
            // email không tồn tại: vẫn băm một lần để thời gian phản hồi không lộ email nào có tài khoản
            auth::verify_password(b.password, st.dummy_hash.as_ref().clone()).await;
            false
        }
    };
    let Some((id, _, name, email)) = row.filter(|_| ok) else {
        st.limiter.record(&ip_key);
        st.limiter.record(&acct_key);
        tracing::warn!(%ip, "login failed");
        return Err(ApiError::Unauthorized);
    };
    st.limiter.clear(&acct_key);
    let tokens = auth::start_session(&st, id).await?;
    Ok(Json(tokens.into_json(json!({ "id": id, "email": email, "name": name }))))
}

#[derive(Deserialize)]
struct RefreshReq {
    refresh_token: String,
}

async fn refresh(
    State(st): State<AppState>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    headers: HeaderMap,
    Json(b): Json<RefreshReq>,
) -> ApiResult<Json<Value>> {
    let ip = peer_ip(&st, &headers, peer);
    let key = format!("refresh-ip:{ip}");
    st.limiter.check(&key, REFRESH_FAIL_PER_IP, LOGIN_WINDOW)?;
    match auth::rotate(&st, b.refresh_token.trim()).await {
        Ok((user, tokens)) => {
            let (id, email, name): (Uuid, String, String) =
                sqlx::query_as("SELECT id, email, name FROM users WHERE id = $1").bind(user).fetch_one(&st.db).await?;
            Ok(Json(tokens.into_json(json!({ "id": id, "email": email, "name": name }))))
        }
        Err(e) => {
            if matches!(e, ApiError::Unauthorized) {
                st.limiter.record(&key);
            }
            Err(e)
        }
    }
}

/// Đăng xuất thiết bị hiện tại: thu hồi phiên của refresh token gửi lên (luôn 204).
async fn logout(State(st): State<AppState>, Json(b): Json<RefreshReq>) -> ApiResult<StatusCode> {
    if b.refresh_token.len() <= 200 {
        auth::revoke_session(&st, b.refresh_token.trim()).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Đăng xuất mọi thiết bị (vd nghi bị lộ). Access token đang sống tối đa 15 phút nữa mới hết hạn.
async fn logout_all(State(st): State<AppState>, AuthUser(uid): AuthUser) -> ApiResult<Json<Value>> {
    let n = auth::revoke_all(&st, uid).await?;
    Ok(Json(json!({ "revoked_sessions": n })))
}

async fn me(State(st): State<AppState>, AuthUser(uid): AuthUser) -> ApiResult<Json<Value>> {
    let (id, email, name): (Uuid, String, String) =
        sqlx::query_as("SELECT id, email, name FROM users WHERE id = $1")
            .bind(uid)
            .fetch_one(&st.db)
            .await?;
    let tenants: Vec<(Uuid, String, String)> = sqlx::query_as(
        "SELECT t.id, t.name, tm.role FROM tenants t JOIN tenant_members tm ON tm.tenant_id = t.id WHERE tm.user_id = $1 ORDER BY t.created_at",
    )
    .bind(uid)
    .fetch_all(&st.db)
    .await?;
    let tenants: Vec<Value> = tenants.into_iter().map(|(id, name, role)| json!({"id": id, "name": name, "role": role})).collect();
    Ok(Json(json!({ "id": id, "email": email, "name": name, "tenants": tenants })))
}

// ───────────────────────── tenant / home ─────────────────────────

#[derive(Deserialize)]
struct NameReq {
    name: String,
}

async fn create_tenant(State(st): State<AppState>, AuthUser(uid): AuthUser, Json(b): Json<NameReq>) -> ApiResult<(StatusCode, Json<Value>)> {
    let name = non_empty(&b.name, "name", 100)?;
    let mut tx = st.db.begin().await?;
    let id: Uuid = sqlx::query_scalar("INSERT INTO tenants (name) VALUES ($1) RETURNING id")
        .bind(&name)
        .fetch_one(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO tenant_members (tenant_id, user_id, role) VALUES ($1,$2,'owner')")
        .bind(id)
        .bind(uid)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": id, "name": name }))))
}

#[derive(Deserialize)]
struct CreateHomeReq {
    name: String,
    address: Option<String>,
    timezone: Option<String>,
}

async fn create_home(
    State(st): State<AppState>,
    AuthUser(uid): AuthUser,
    Path(tid): Path<Uuid>,
    Json(b): Json<CreateHomeReq>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let is_admin: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM tenant_members WHERE tenant_id=$1 AND user_id=$2)",
    )
    .bind(tid)
    .bind(uid)
    .fetch_one(&st.db)
    .await?;
    if !is_admin {
        return Err(ApiError::NotFound);
    }
    let name = non_empty(&b.name, "name", 100)?;
    let tz = b.timezone.unwrap_or_else(|| "Asia/Ho_Chi_Minh".into());
    let mut tx = st.db.begin().await?;
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO homes (tenant_id, name, address, timezone) VALUES ($1,$2,$3,$4) RETURNING id",
    )
    .bind(tid)
    .bind(&name)
    .bind(&b.address)
    .bind(&tz)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO home_members (home_id, user_id, role) VALUES ($1,$2,'owner')")
        .bind(id)
        .bind(uid)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": id, "tenant_id": tid, "name": name, "address": b.address, "timezone": tz }))))
}

#[derive(Serialize, FromRow)]
struct HomeOut {
    id: Uuid,
    tenant_id: Uuid,
    name: String,
    address: Option<String>,
    timezone: String,
    role: String,
}

async fn list_homes(State(st): State<AppState>, AuthUser(uid): AuthUser) -> ApiResult<Json<Vec<HomeOut>>> {
    let rows = sqlx::query_as::<_, HomeOut>(
        "SELECT h.id, h.tenant_id, h.name, h.address, h.timezone, COALESCE(hm.role, 'admin') AS role
         FROM homes h
         LEFT JOIN home_members   hm ON hm.home_id = h.id AND hm.user_id = $1
         LEFT JOIN tenant_members tm ON tm.tenant_id = h.tenant_id AND tm.user_id = $1
         WHERE hm.user_id IS NOT NULL OR tm.user_id IS NOT NULL
         ORDER BY h.created_at",
    )
    .bind(uid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

// ───────────────────────── members & invites ─────────────────────────

#[derive(Serialize, FromRow)]
struct MemberOut {
    user_id: Uuid,
    name: String,
    email: String,
    role: String,
}

async fn list_members(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<MemberOut>>> {
    access::require(&st.db, uid, hid, Role::Guest).await?;
    let rows = sqlx::query_as::<_, MemberOut>(
        "SELECT u.id AS user_id, u.name, u.email, hm.role FROM home_members hm JOIN users u ON u.id = hm.user_id
         WHERE hm.home_id = $1 ORDER BY hm.created_at",
    )
    .bind(hid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn remove_member(State(st): State<AppState>, AuthUser(uid): AuthUser, Path((hid, target)): Path<(Uuid, Uuid)>) -> ApiResult<StatusCode> {
    // Tự rời căn hộ thì không cần quyền admin; xoá người khác cần Admin.
    let role = access::require(&st.db, uid, hid, if uid == target { Role::Guest } else { Role::Admin }).await?;
    let target_role: Option<String> = sqlx::query_scalar("SELECT role FROM home_members WHERE home_id=$1 AND user_id=$2")
        .bind(hid)
        .bind(target)
        .fetch_optional(&st.db)
        .await?;
    let target_role = target_role.ok_or(ApiError::NotFound)?;
    if target_role == "owner" {
        return Err(ApiError::Forbidden); // không xoá owner (cần cơ chế chuyển quyền riêng)
    }
    if target_role == "admin" && role < Role::Owner && uid != target {
        return Err(ApiError::Forbidden);
    }
    sqlx::query("DELETE FROM home_members WHERE home_id=$1 AND user_id=$2")
        .bind(hid)
        .bind(target)
        .execute(&st.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct InviteReq {
    role: String,
}

async fn create_invite(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<InviteReq>) -> ApiResult<(StatusCode, Json<Value>)> {
    let my = access::require(&st.db, uid, hid, Role::Admin).await?;
    let role = Role::parse(&b.role).filter(|r| *r != Role::Owner).ok_or_else(|| ApiError::BadRequest("role must be admin|member|guest".into()))?;
    if role == Role::Admin && my < Role::Owner {
        return Err(ApiError::Forbidden);
    }
    let token = auth::random_token("inv");
    sqlx::query("INSERT INTO home_invites (token_hash, home_id, role, created_by, expires_at) VALUES ($1,$2,$3,$4, now() + interval '7 days')")
        .bind(auth::hash_token(&token))
        .bind(hid)
        .bind(b.role)
        .bind(uid)
        .execute(&st.db)
        .await?;
    Ok((StatusCode::CREATED, Json(json!({ "token": token, "expires_in_days": 7 }))))
}

#[derive(Deserialize)]
struct AcceptReq {
    token: String,
}

async fn accept_invite(State(st): State<AppState>, AuthUser(uid): AuthUser, Json(b): Json<AcceptReq>) -> ApiResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    // Dùng 1 lần, nguyên tử.
    let row: Option<(Uuid, String)> = sqlx::query_as(
        "UPDATE home_invites SET used_at = now()
         WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now()
         RETURNING home_id, role",
    )
    .bind(auth::hash_token(b.token.trim()))
    .fetch_optional(&mut *tx)
    .await?;
    let (home_id, role) = row.ok_or_else(|| ApiError::BadRequest("invalid or expired invite".into()))?;
    // Giữ vai trò cao hơn nếu đã là thành viên.
    sqlx::query(
        "INSERT INTO home_members (home_id, user_id, role) VALUES ($1,$2,$3)
         ON CONFLICT (home_id, user_id) DO NOTHING",
    )
    .bind(home_id)
    .bind(uid)
    .bind(&role)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(json!({ "home_id": home_id, "role": role })))
}

// ───────────────────────── gateways ─────────────────────────

async fn create_gateway(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<NameReq>) -> ApiResult<(StatusCode, Json<Value>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = non_empty(&b.name, "name", 100)?;
    let token = auth::random_token("gw");
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO gateways (tenant_id, home_id, name, token_hash)
         SELECT tenant_id, id, $2, $3 FROM homes WHERE id = $1 RETURNING id",
    )
    .bind(hid)
    .bind(&name)
    .bind(auth::hash_token(&token))
    .fetch_one(&st.db)
    .await?;
    // Token chỉ trả về MỘT lần.
    Ok((StatusCode::CREATED, Json(json!({ "id": id, "name": name, "token": token }))))
}

async fn list_gateways(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Value>> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let rows: Vec<(Uuid, String, Option<DateTime<Utc>>, i64)> = sqlx::query_as(
        "SELECT g.id, g.name, g.last_seen_at, (SELECT count(*) FROM devices d WHERE d.gateway_id = g.id)
         FROM gateways g WHERE g.home_id = $1 ORDER BY g.created_at",
    )
    .bind(hid)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(json!({
        "online": st.hub.gateway_online(hid),
        "gateways": rows.into_iter().map(|(id, name, seen, devices)| json!({
            "id": id, "name": name, "last_seen_at": seen, "device_count": devices, "online": st.hub.gateway_connected(id)
        })).collect::<Vec<_>>()
    })))
}

async fn gateway_home(st: &AppState, gid: Uuid) -> ApiResult<Uuid> {
    sqlx::query_scalar("SELECT home_id FROM gateways WHERE id = $1")
        .bind(gid)
        .fetch_optional(&st.db)
        .await?
        .ok_or(ApiError::NotFound)
}

/// Thu hồi token cũ và cấp token mới (thiết bị, phòng, tên được giữ nguyên). Kết nối đang mở bị ngắt ngay.
async fn rotate_gateway(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(gid): Path<Uuid>) -> ApiResult<Json<Value>> {
    let hid = gateway_home(&st, gid).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let token = auth::random_token("gw");
    sqlx::query("UPDATE gateways SET token_hash = $2 WHERE id = $1")
        .bind(gid)
        .bind(auth::hash_token(&token))
        .execute(&st.db)
        .await?;
    st.hub.kick_gateway(gid);
    if !st.hub.gateway_online(hid) {
        st.hub.publish(hid, json!({"type": "gateway", "online": false}).to_string());
    }
    tracing::warn!(gateway = %gid, user = %uid, "gateway token rotated");
    Ok(Json(json!({ "id": gid, "token": token })))
}

/// Xoá gateway. Các thiết bị thuộc gateway này bị xoá theo (ON DELETE CASCADE).
async fn delete_gateway(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(gid): Path<Uuid>) -> ApiResult<StatusCode> {
    let hid = gateway_home(&st, gid).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("DELETE FROM gateways WHERE id = $1").bind(gid).execute(&st.db).await?;
    st.hub.kick_gateway(gid);
    st.hub.publish(hid, json!({"type": "devices_changed"}).to_string());
    if !st.hub.gateway_online(hid) {
        st.hub.publish(hid, json!({"type": "gateway", "online": false}).to_string());
    }
    tracing::warn!(gateway = %gid, user = %uid, "gateway deleted");
    Ok(StatusCode::NO_CONTENT)
}

// ───────────────────────── rooms ─────────────────────────

#[derive(Serialize, FromRow)]
struct RoomOut {
    id: Uuid,
    home_id: Uuid,
    name: String,
    icon: Option<String>,
}

const ROOM_ICONS: [&str; 12] = [
    "living", "bedroom", "kitchen", "bathroom", "dining", "office", "balcony", "garage", "kids", "laundry", "hallway", "other",
];

fn validate_icon(icon: &str) -> ApiResult<()> {
    if ROOM_ICONS.contains(&icon) {
        Ok(())
    } else {
        Err(ApiError::BadRequest(format!("invalid room icon: {icon}")))
    }
}

#[derive(Deserialize)]
struct CreateRoomReq {
    name: String,
    icon: Option<String>,
}

#[derive(Deserialize)]
struct UpdateRoomReq {
    name: Option<String>,
    icon: Option<String>,
}

async fn list_rooms(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<RoomOut>>> {
    access::require(&st.db, uid, hid, Role::Guest).await?;
    Ok(Json(
        sqlx::query_as::<_, RoomOut>("SELECT id, home_id, name, icon FROM rooms WHERE home_id=$1 ORDER BY name")
            .bind(hid)
            .fetch_all(&st.db)
            .await?,
    ))
}

async fn create_room(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<CreateRoomReq>) -> ApiResult<(StatusCode, Json<RoomOut>)> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = non_empty(&b.name, "name", 100)?;
    if let Some(i) = &b.icon {
        validate_icon(i)?;
    }
    let room = sqlx::query_as::<_, RoomOut>("INSERT INTO rooms (home_id, name, icon) VALUES ($1,$2,$3) RETURNING id, home_id, name, icon")
        .bind(hid)
        .bind(name)
        .bind(&b.icon)
        .fetch_one(&st.db)
        .await?;
    Ok((StatusCode::CREATED, Json(room)))
}

async fn room_home(st: &AppState, rid: Uuid) -> ApiResult<Uuid> {
    sqlx::query_scalar("SELECT home_id FROM rooms WHERE id=$1")
        .bind(rid)
        .fetch_optional(&st.db)
        .await?
        .ok_or(ApiError::NotFound)
}

async fn update_room(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(rid): Path<Uuid>, Json(b): Json<UpdateRoomReq>) -> ApiResult<Json<RoomOut>> {
    let hid = room_home(&st, rid).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    let name = b.name.as_deref().map(|n| non_empty(n, "name", 100)).transpose()?;
    if let Some(i) = &b.icon {
        validate_icon(i)?;
    }
    Ok(Json(
        sqlx::query_as::<_, RoomOut>(
            "UPDATE rooms SET name = COALESCE($2, name), icon = COALESCE($3, icon) WHERE id = $1 RETURNING id, home_id, name, icon",
        )
        .bind(rid)
        .bind(name)
        .bind(&b.icon)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn delete_room(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(rid): Path<Uuid>) -> ApiResult<StatusCode> {
    let hid = room_home(&st, rid).await?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    sqlx::query("DELETE FROM rooms WHERE id=$1").bind(rid).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

// ───────────────────────── devices ─────────────────────────

#[derive(Serialize, FromRow)]
struct DeviceOut {
    id: Uuid,
    home_id: Uuid,
    room_id: Option<Uuid>,
    name: String,
    friendly_name: String,
    ieee_address: String,
    vendor: Option<String>,
    model: Option<String>,
    kind: String,
    description: Option<String>,
    channels: Value,
    exposes: Value,
    state: Value,
    online: bool,
    last_seen_at: Option<DateTime<Utc>>,
}

async fn list_devices(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Json<Vec<DeviceOut>>> {
    access::require(&st.db, uid, hid, Role::Guest).await?;
    Ok(Json(
        sqlx::query_as::<_, DeviceOut>(
            "SELECT id, home_id, room_id, name, friendly_name, ieee_address, vendor, model, kind, description, channels, exposes, state, online, last_seen_at
             FROM devices WHERE home_id = $1 ORDER BY name",
        )
        .bind(hid)
        .fetch_all(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct UpdateDeviceReq {
    name: Option<String>,
    room_id: Option<Uuid>,
    #[serde(default)]
    clear_room: bool,
    /// Thay toàn bộ tên/loại tải của các gang: {"state_1":{"name":"Đèn trần","type":"light"}}
    channels: Option<Value>,
}

const CHANNEL_TYPES: [&str; 6] = ["light", "fan", "outlet", "air_conditioner", "water_heater", "other"];

fn validate_channels(v: &Value) -> ApiResult<Value> {
    let obj = v
        .as_object()
        .filter(|o| o.len() <= 8)
        .ok_or_else(|| ApiError::BadRequest("channels must be an object (<=8 keys)".into()))?;
    let mut out = serde_json::Map::new();
    for (k, c) in obj {
        let key_ok = k == "state"
            || k.strip_prefix("state_")
                .is_some_and(|r| !r.is_empty() && r.len() <= 10 && r.chars().all(|c| c.is_ascii_alphanumeric()));
        if !key_ok {
            return Err(ApiError::BadRequest(format!("invalid channel key: {k}")));
        }
        let name = c.get("name").and_then(Value::as_str).unwrap_or("").trim();
        if name.chars().count() > 60 {
            return Err(ApiError::BadRequest("channel name must be <= 60 chars".into()));
        }
        let ty = c.get("type").and_then(Value::as_str).unwrap_or("other");
        if !CHANNEL_TYPES.contains(&ty) {
            return Err(ApiError::BadRequest(format!("invalid channel type: {ty}")));
        }
        out.insert(k.clone(), json!({ "name": name, "type": ty }));
    }
    Ok(Value::Object(out))
}

async fn update_device(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(did): Path<Uuid>, Json(b): Json<UpdateDeviceReq>) -> ApiResult<StatusCode> {
    let hid: Uuid = sqlx::query_scalar("SELECT home_id FROM devices WHERE id=$1")
        .bind(did)
        .fetch_optional(&st.db)
        .await?
        .ok_or(ApiError::NotFound)?;
    access::require(&st.db, uid, hid, Role::Admin).await?;
    if let Some(n) = &b.name {
        let n = non_empty(n, "name", 100)?;
        sqlx::query("UPDATE devices SET name=$2 WHERE id=$1").bind(did).bind(n).execute(&st.db).await?;
    }
    if let Some(ch) = &b.channels {
        let ch = validate_channels(ch)?;
        sqlx::query("UPDATE devices SET channels=$2 WHERE id=$1").bind(did).bind(ch).execute(&st.db).await?;
    }
    if let Some(rid) = b.room_id {
        if room_home(&st, rid).await? != hid {
            return Err(ApiError::BadRequest("room belongs to another home".into()));
        }
        sqlx::query("UPDATE devices SET room_id=$2 WHERE id=$1").bind(did).bind(rid).execute(&st.db).await?;
    } else if b.clear_room {
        sqlx::query("UPDATE devices SET room_id=NULL WHERE id=$1").bind(did).execute(&st.db).await?;
    }
    st.hub.publish(hid, json!({"type": "devices_changed"}).to_string());
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct CommandReq {
    payload: Value,
}

/// Chỉ cho phép một tập thuộc tính điều khiển an toàn; không cho client gửi payload tuỳ ý xuống Zigbee2MQTT.
pub(crate) fn validate_command(p: &Value) -> ApiResult<()> {
    let obj = p.as_object().filter(|o| !o.is_empty() && o.len() <= 8).ok_or_else(|| ApiError::BadRequest("payload must be a non-empty object (<=8 keys)".into()))?;
    for (k, v) in obj {
        // key = <prop> hoặc <prop>_<endpoint> (vd state, state_1, brightness_2, color_temp)
        let (prop, rest) = ["state", "brightness", "color_temp"]
            .iter()
            .find_map(|p| k.strip_prefix(p).map(|r| (*p, r)))
            .ok_or_else(|| ApiError::BadRequest(format!("property not allowed: {k}")))?;
        if !(rest.is_empty() || (rest.starts_with('_') && rest.len() <= 12 && rest[1..].chars().all(|c| c.is_ascii_alphanumeric()))) {
            return Err(ApiError::BadRequest(format!("property not allowed: {k}")));
        }
        let ok = match prop {
            "state" => matches!(v.as_str(), Some("ON" | "OFF" | "TOGGLE")),
            "brightness" => v.as_u64().map(|n| n <= 254).unwrap_or(false),
            _ => v.as_u64().map(|n| (1..=1000).contains(&n)).unwrap_or(false),
        };
        if !ok {
            return Err(ApiError::BadRequest(format!("invalid value for {k}")));
        }
    }
    Ok(())
}

async fn command(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(did): Path<Uuid>, Json(b): Json<CommandReq>) -> ApiResult<(StatusCode, Json<Value>)> {
    let (hid, gw, fname): (Uuid, Uuid, String) = sqlx::query_as("SELECT home_id, gateway_id, friendly_name FROM devices WHERE id=$1")
        .bind(did)
        .fetch_optional(&st.db)
        .await?
        .ok_or(ApiError::NotFound)?;
    access::require(&st.db, uid, hid, Role::Member).await?;
    validate_command(&b.payload)?;

    let msg = json!({ "type": "set", "friendly_name": fname, "payload": b.payload }).to_string();
    if !st.hub.send_gateway(gw, msg).await {
        return Err(ApiError::Unavailable("gateway offline".into()));
    }
    sqlx::query("INSERT INTO command_log (device_id, home_id, user_id, payload) VALUES ($1,$2,$3,$4)")
        .bind(did)
        .bind(hid)
        .bind(uid)
        .bind(&b.payload)
        .execute(&st.db)
        .await?;
    // 202: lệnh đã chuyển xuống gateway. Trạng thái thật đến qua WebSocket khi thiết bị xác nhận.
    Ok((StatusCode::ACCEPTED, Json(json!({ "status": "sent" }))))
}

// ───────────────────────── Matter bridge ─────────────────────────
//
// Matter chạy trên mạng LAN của nhà nên bridge (Matterbridge) nằm trên Pi, không phải cloud. Cloud chỉ
// hỏi gateway qua WebSocket khi app cần: không lưu mã ghép nối vào DB/log (đây là bí mật cho phép thêm người
// điều khiển nhà). Chỉ admin/owner của căn hộ được xem hoặc thao tác.

#[derive(Serialize, Deserialize)]
struct MatterFabric {
    index: u64,
    #[serde(default)]
    label: String,
    #[serde(default)]
    vendor: String,
}

#[derive(Serialize, Deserialize)]
struct MatterInfo {
    available: bool,
    #[serde(default)]
    online: bool,
    #[serde(default)]
    commissioned: bool,
    #[serde(default)]
    pairing_open: bool,
    qr: Option<String>,
    manual_code: Option<String>,
    #[serde(default)]
    fabrics: Vec<MatterFabric>,
}

impl MatterInfo {
    /// Không tin dữ liệu gateway: chỉ chuyển tiếp mã đúng định dạng Matter, và chỉ khi đang cho phép ghép nối.
    fn sanitize(mut self) -> Self {
        let qr_ok = |q: &str| q.starts_with("MT:") && q.len() <= 64 && q.chars().all(|c| c.is_ascii_alphanumeric() || c == ':' || c == '.' || c == '-');
        let manual_ok = |m: &str| (11..=21).contains(&m.len()) && m.chars().all(|c| c.is_ascii_digit());
        if !self.pairing_open || !self.qr.as_deref().is_some_and(qr_ok) {
            self.qr = None;
        }
        if !self.pairing_open || !self.manual_code.as_deref().is_some_and(manual_ok) {
            self.manual_code = None;
        }
        self.fabrics.truncate(32);
        self
    }
}

async fn matter_request(st: &AppState, hid: Uuid, msg: Value) -> ApiResult<Response> {
    let gw = st.hub.gateway_for_home(hid).ok_or_else(|| ApiError::Unavailable("gateway offline".into()))?;
    let reply = st
        .hub
        .request_gateway(gw, msg, std::time::Duration::from_secs(15))
        .await
        .map_err(|e| match e {
            crate::hub::RequestError::Offline => ApiError::Unavailable("gateway offline".into()),
            crate::hub::RequestError::Timeout => ApiError::Unavailable("gateway did not respond".into()),
        })?;
    if reply.get("error").is_some_and(|e| !e.is_null()) {
        return Err(ApiError::Unavailable("matter bridge unavailable".into()));
    }
    let info: MatterInfo = serde_json::from_value(reply["info"].clone()).map_err(|e| ApiError::Internal(anyhow::anyhow!("bad matter reply: {e}")))?;
    // no-store: phản hồi chứa mã ghép nối, không để proxy/trình duyệt lưu lại.
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(info.sanitize())).into_response())
}

async fn matter_info(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>) -> ApiResult<Response> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    matter_request(&st, hid, json!({ "type": "matter_get" })).await
}

#[derive(Deserialize)]
struct PairingReq {
    open: bool,
}

async fn matter_pairing(State(st): State<AppState>, AuthUser(uid): AuthUser, Path(hid): Path<Uuid>, Json(b): Json<PairingReq>) -> ApiResult<Response> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    tracing::warn!(home = %hid, user = %uid, open = b.open, "matter pairing window requested");
    matter_request(&st, hid, json!({ "type": "matter_pairing", "open": b.open })).await
}

async fn matter_remove_fabric(State(st): State<AppState>, AuthUser(uid): AuthUser, Path((hid, index)): Path<(Uuid, u64)>) -> ApiResult<Response> {
    access::require(&st.db, uid, hid, Role::Admin).await?;
    tracing::warn!(home = %hid, user = %uid, fabric = index, "matter controller removed");
    matter_request(&st, hid, json!({ "type": "matter_remove_fabric", "fabric_index": index })).await
}
