const std = @import("std");

/// Funnel error types.
pub const funnel_errors = error{
    pipe_too_many_descriptors,
    pipe_system_table_full,
    pipe_invalid_fds_buffer,
    pipe_invalid_flags,

    would_block,
    not_c_error,
};

export const funnel_notifs_t = enum(c_int) {
    SUCCESS,
    WOULD_BLOCK,
};

export const marshal_func = fn (*anyopaque) [*]const u8;
export const unmarshal_func = fn ([*]const u8) *anyopaque;
export const size_func = fn (void) usize;
export const funnel_callback = fn (*anyopaque) void;

pub fn error_to_c_error(e: funnel_errors) funnel_errors!c_int {
    return switch (e) {
        funnel_errors.pipe_too_many_descriptors => return std.os.linux.E.MFILE,
        funnel_errors.pipe_system_table_full => return std.os.linux.E.NFILE,
        funnel_errors.pipe_invalid_fds_buffer => return std.os.linux.E.FAULT,
        funnel_errors.pipe_invalid_flags => return std.os.linux.E.INVAL,
        else => -1,
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

export const Event = struct {
    payload: *anyopaque,
};

export const EventMarshaller = struct {
    marshal: ?*marshal_func = undefined,
    unmarshal: ?*unmarshal_func = undefined,
    size: ?*size_func = undefined,
};

export const Funnel = struct {
    alloc: std.mem.Allocator = undefined,
    fds: [2]std.c.fd_t = undefined,
    lock: std.Thread.Mutex = undefined,
    marshaller: EventMarshaller = undefined,
    event_buffer: []u8 = undefined,

    pub fn init(alloc: std.mem.Allocator, marshaller: EventMarshaller) funnel_errors!Funnel {
        var result: Funnel = undefined;
        const err = std.c.pipe2(&result.fds, std.c.O.NONBLOCK);
        try pipe_error(err);
        result.lock = std.Thread.Mutex{};
        result.marshaller = marshaller;
        result.alloc = alloc;
        if (result.marshaller.size) |size_fn| {
            result.event_buffer = try result.alloc.alloc(u8, size_fn());
        }
        return result;
    }

    fn readFd(self: *Funnel) std.c.fd_t {
        return self.fds[0];
    }
    fn writeFd(self: *Funnel) std.c.fd_t {
        return self.fds[1];
    }

    pub fn write(self: *Funnel, e: Event) funnel_errors!usize {
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            var n: usize = 0;
            if (self.marshaller.marshal) |marshal_fn| {
                const buffer = marshal_fn(e.payload);
                const len = std.mem.len(buffer);
                n = std.c.fwrite(buffer, @sizeOf(u8), len, self.writeFd());
            }
            return n;
        }
        return funnel_errors.would_block;
    }

    pub fn read(self: *Funnel, cb: funnel_callback) funnel_errors!usize {
        var result_n: usize = 0;
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            result_n = std.c.fread(self.event_buffer, @sizeOf(u8), self.marshaller.size(), self.readFd());
            if (result_n > 0) {
                if (self.marshaller.unmarshal) |unmarshal_fn| {
                    const event = unmarshal_fn(self.event_buffer);
                    cb(event);
                }
            }
            return result_n;
        }
        return funnel_errors.would_block;
    }
};

export fn funnel_init(fun: *Funnel, marshaller: EventMarshaller) c_int {
    const result = Funnel.init(std.heap.page_allocator, marshaller) catch |err| {
        return error_to_c_error(err);
    };
    fun.* = result;
    return 0;
}

export const funnel_result = struct {
    result: funnel_notifs_t = funnel_notifs_t.SUCCESS,
    len: usize = 0,
};

export fn funnel_write(fun: *Funnel, e: Event) funnel_result {
    var result: funnel_result = undefined;
    const n = fun.write(e) catch {
        result.result = funnel_notifs_t.WOULD_BLOCK;
    };
    result.len = n;
    return result;
}
