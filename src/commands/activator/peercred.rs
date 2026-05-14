use anyhow::{Context, Result};
use std::os::fd::BorrowedFd;

#[derive(Debug, Clone, Copy)]
pub struct PeerCredentials {
    pub pid: i32,
    pub uid: u32,
    pub gid: u32,
}

pub fn get(fd: BorrowedFd<'_>) -> Result<PeerCredentials> {
    let ucred = rustix::net::sockopt::socket_peercred(fd).context("getsockopt SO_PEERCRED")?;
    Ok(PeerCredentials {
        pid: ucred.pid.as_raw_nonzero().get(),
        uid: ucred.uid.as_raw(),
        gid: ucred.gid.as_raw(),
    })
}

pub fn is_authorized(creds: &PeerCredentials, allowed_gids: &[u32]) -> bool {
    creds.uid == 0 || allowed_gids.contains(&creds.gid)
}
