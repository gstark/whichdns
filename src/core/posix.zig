//! C declarations shared by the POSIX application and UDP transports.

pub const c = @cImport({
    // Optimized builds define _FORTIFY_SOURCE, and translate-c cannot handle
    // glibc's fortified open() wrappers in bits/fcntl2.h.
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("arpa/inet.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("netdb.h");
    @cInclude("net/if.h");
    @cInclude("stdio.h");
    @cInclude("netinet/in.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/time.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const errno = @import("std").c.errno;
