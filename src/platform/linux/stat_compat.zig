//! Kernel 4.9 lacks statx(2) (merged in 4.11), but std.fs.File.stat() calls it
//! unconditionally on Linux and panics on ENOSYS. Platform code must never
//! call std stat helpers; use this raw fstat/fstatat shim instead.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Error = error{
    BadFileDescriptor,
    SystemResources,
};

/// Raw fstat(2) via the aarch64 syscall. Returns the kernel stat layout;
/// callers read `.size`, `.mode`, `.mtim` directly.
pub fn fstat(fd: posix.fd_t) Error!linux.Stat {
    var st: linux.Stat = undefined;
    const rc = linux.fstat(fd, &st);
    return switch (posix.errno(rc)) {
        .SUCCESS => st,
        .BADF => error.BadFileDescriptor,
        .NOMEM => error.SystemResources,
        else => unreachable, // fstat(2) documents no other errors
    };
}
