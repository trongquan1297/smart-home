//! Danh sách camera lưu tại addon (gồm mật khẩu camera). Cloud chỉ giữ tên/phòng/khả năng, không giữ mật khẩu.
use std::{collections::HashMap, path::PathBuf};

use serde::{Deserialize, Serialize};

use super::onvif::Probe;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Camera {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    /// Có ONVIF: luồng/PTZ/sự kiện đọc từ camera. Không có: chỉ có `rtsp_url` người dùng nhập.
    pub onvif: Option<Probe>,
    pub rtsp_url: String,
}

pub struct Store {
    path: PathBuf,
    pub cameras: HashMap<String, Camera>,
}

impl Store {
    pub fn load(path: PathBuf) -> Self {
        let cameras = std::fs::read(&path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Store { path, cameras }
    }

    pub fn save(&self) -> std::io::Result<()> {
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(&self.cameras)?)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?; // có mật khẩu camera
        }
        std::fs::rename(tmp, &self.path)
    }
}
