const std = @import("std");

/// Funnel error types.
pub const funnel_errors = error{
    pipe_too_many_descriptors,
    pipe_system_table_full,
    pipe_invalid_fds_buffer,
    pipe_invalid_flags,

    would_block,
    closed,
};

pub const funnel_notifs_t = enum(c_int) {
    SUCCESS,
    WOULD_BLOCK,
    CLOSED,
};

pub const marshal_func = fn (*anyopaque) callconv(.C) [*]const u8;
pub const unmarshal_func = fn ([*]const u8) callconv(.C) *anyopaque;
pub const size_func = fn () callconv(.C) usize;
pub const funnel_callback = fn (*anyopaque) callconv(.C) void;

pub fn error_to_c_error(e: funnel_errors) c_int {
    return switch (e) {
        funnel_errors.pipe_too_many_descriptors => return std.os.linux.E.MFILE,
        funnel_errors.pipe_system_table_full => return std.os.linux.E.NFILE,
        funnel_errors.pipe_invalid_fds_buffer => return std.os.linux.E.FAULT,
        funnel_errors.pipe_invalid_flags => return std.os.linux.E.INVAL,
        funnel_errors.would_block => return funnel_notifs_t.WOULD_BLOCK,
        funnel_errors.closed => funnel_notifs_t.CLOSED,
    };
}

/// returns the proper funnel_error type for the given POSIX error.
fn pipe_error(err: c_int) !void {
    if (err == -1) {
        const e = std.c._errno();
        if (e == std.os.linux.E.MFILE) return funnel_errors.pipe_too_many_descriptors;
        if (e == std.os.linux.E.NFILE) return funnel_errors.pipe_system_table_full;
        if (e == std.os.linux.E.FAULT) return funnel_errors.pipe_invalid_fds_buffer;
        if (e == std.os.linux.E.INVAL) return funnel_errors.pipe_invalid_flags;
    }
    return;
}

pub const Event = extern struct {
    payload: *anyopaque,
};

pub const EventMarshaller = extern struct {
    marshal: ?*marshal_func = undefined,
    unmarshal: ?*unmarshal_func = undefined,
    size: ?*size_func = undefined,
};

pub const funnel_t = extern struct {
    fds: [2]std.c.fd_t = undefined,
    marshaller: EventMarshaller = undefined,
    event_buffer: [*]u8 = undefined,
};

pub const Funnel = struct {
    alloc: std.mem.Allocator = undefined,
    lock: std.Thread.Mutex = undefined,
    funnel: funnel_t = funnel_t{},
    closed: bool = false,

    pub fn init(alloc: std.mem.Allocator, marshaller: EventMarshaller) funnel_errors!Funnel {
        var result: Funnel = Funnel{};
        const err = std.c.pipe2(&result.funnel.fds, std.c.O.NONBLOCK);
        try pipe_error(err);
        result.lock = std.Thread.Mutex{};
        result.funnel.marshaller = marshaller;
        result.alloc = alloc;
        if (result.funnel.marshaller.size) |size_fn| {
            result.funnel.event_buffer = try result.alloc.alloc(u8, size_fn());
        }
        result.closed = false;
        return result;
    }

    fn readFd(self: *Funnel) std.c.fd_t {
        return self.funnel.fds[0];
    }
    fn writeFd(self: *Funnel) std.c.fd_t {
        return self.funnel.fds[1];
    }

    pub fn write(self: *Funnel, e: Event) funnel_errors!usize {
        if (self.closed) return funnel_errors.closed;
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            var n: usize = 0;
            if (self.funnel.marshaller.marshal) |marshal_fn| {
                const buffer = marshal_fn(e.payload);
                const len = std.mem.len(buffer);
                n = std.c.fwrite(buffer, @sizeOf(u8), len, self.funnel.writeFd());
            }
            return n;
        }
        return funnel_errors.would_block;
    }

    pub fn read(self: *Funnel, cb: *const funnel_callback) funnel_errors!usize {
        if (self.closed) return funnel_errors.closed;
        var result_n: usize = 0;
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            result_n = std.c.fread(self.funnel.event_buffer, @sizeOf(u8), self.funnel.marshaller.size(), self.funnel.readFd());
            if (result_n > 0) {
                if (self.funnel.marshaller.unmarshal) |unmarshal_fn| {
                    const event = unmarshal_fn(self.funnel.event_buffer);
                    cb(event);
                }
            }
            return result_n;
        }
        return funnel_errors.would_block;
    }

    pub fn deinit(self: *Funnel) void {
        if (self.closed) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.alloc.free(self.funnel.event_buffer);
        std.c.close(self.funnel.readFd());
        std.c.close(self.funnel.writeFd());
        self.closed = true;
    }
};

pub export fn funnel_init(fun: *Funnel, marshaller: EventMarshaller) c_int {
    const result = Funnel.init(std.heap.page_allocator, marshaller) catch |err| {
        return error_to_c_error(err);
    };
    fun.* = result;
    return 0;
}

pub const funnel_result = extern struct {
    result: c_int = @intFromEnum(funnel_notifs_t.SUCCESS),
    len: usize = 0,
};

pub export fn funnel_write(fun: *Funnel, e: Event) funnel_result {
    var result = funnel_result{};
    var n: usize = 0;
    n = fun.write(e) catch |err| {
        result.result = error_to_c_error(err);
    };
    result.len = n;
    return result;
}

pub export fn funnel_read(fun: *Funnel, cb: *const funnel_callback) funnel_result {
    var result = funnel_result{};
    var n: usize = 0;
    n = fun.read(cb) catch |err| {
        result.result = error_to_c_error(err);
    };
    result.len = n;
    return result;
}

pub export fn funnel_release(fun: *Funnel) void {
    fun.deinit();
}
