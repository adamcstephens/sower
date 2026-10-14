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

/// Network leases authorize the kernel's connection-time group snapshot, not
/// /proc/<pid> (which can race process exit/PID reuse). Keep activation's
/// established primary-GID authorization unchanged.
pub fn is_authorized_socket(
    fd: BorrowedFd<'_>,
    creds: &PeerCredentials,
    allowed_gids: &[u32],
) -> Result<bool> {
    use std::os::fd::AsRawFd;
    unsafe extern "C" {
        fn getsockopt(
            fd: std::ffi::c_int,
            level: std::ffi::c_int,
            name: std::ffi::c_int,
            value: *mut std::ffi::c_void,
            length: *mut u32,
        ) -> std::ffi::c_int;
    }

    if is_authorized(creds, allowed_gids) {
        return Ok(true);
    }
    // Linux SO_PEERGROUPS = 59, SOL_SOCKET = 1. rustix currently exposes
    // SO_PEERCRED but not SO_PEERGROUPS. This small FFI boundary needs no crate.
    let mut groups = vec![0u32; 32];
    for _ in 0..2 {
        let mut length = (groups.len() * std::mem::size_of::<u32>()) as u32;
        // SAFETY: the buffer has `length` writable bytes and socklen_t is u32
        // on Linux. The borrowed socket remains open throughout this call.
        let result = unsafe {
            getsockopt(
                fd.as_raw_fd(),
                1,
                59,
                groups.as_mut_ptr().cast(),
                &mut length,
            )
        };
        let bytes = length as usize;
        anyhow::ensure!(
            bytes.is_multiple_of(std::mem::size_of::<u32>()) && bytes <= 65536 * 4,
            "invalid kernel peer group length"
        );
        if result == 0 {
            anyhow::ensure!(
                bytes <= groups.len() * 4,
                "kernel peer group buffer overflow"
            );
            groups.truncate(bytes / 4);
            return Ok(groups.iter().any(|gid| allowed_gids.contains(gid)));
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(34) || bytes <= groups.len() * 4 {
            return Err(error).context("getsockopt SO_PEERGROUPS");
        }
        groups.resize(bytes / 4, 0);
    }
    anyhow::bail!("kernel peer group snapshot changed unexpectedly")
}
