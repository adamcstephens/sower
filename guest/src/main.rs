use std::io;
use std::os::fd::AsRawFd;

use rustix::net::{AddressFamily, SocketFlags, SocketType, accept_with, listen, socket_with};

#[repr(C)]
struct VsockAddress {
    family: u16,
    reserved: u16,
    port: u32,
    cid: u32,
    flags: u8,
    zero: [u8; 3],
}

unsafe extern "C" {
    fn bind(fd: i32, address: *const VsockAddress, length: u32) -> i32;
}

fn main() -> io::Result<()> {
    let listener = socket_with(
        AddressFamily::VSOCK,
        SocketType::STREAM,
        SocketFlags::CLOEXEC,
        None,
    )?;
    let address = VsockAddress {
        family: AddressFamily::VSOCK.as_raw(),
        reserved: 0,
        port: 5000,
        cid: u32::MAX,
        flags: 0,
        zero: [0; 3],
    };
    // rustix exposes AF_VSOCK sockets but not Linux sockaddr_vm addresses.
    if unsafe {
        bind(
            listener.as_raw_fd(),
            &address,
            std::mem::size_of::<VsockAddress>() as u32,
        )
    } != 0
    {
        return Err(io::Error::last_os_error());
    }
    listen(&listener, 1)?;
    let connection = accept_with(&listener, SocketFlags::CLOEXEC)?;
    drop(listener);
    sower_guest::serve_connection(connection)
}
