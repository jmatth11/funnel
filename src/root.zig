const std = @import("std");

/// Funnel error types.
pub const funnel_errors = error{
    pipe_too_many_descriptors,
    pipe_system_table_full,
    pipe_invalid_fds_buffer,
    pipe_invalid_flags,

    would_block,
};

export const funnel_notifs_t = enum(c_int) {
    SUCCESS,
    WOULD_BLOCK,
};

export const marshal_func = fn (*anyopaque) [*]const u8;
export const unmarshal_func = fn ([*]const u8) *anyopaque;
export const funnel_callback = fn (*anyopaque) void;

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

export const Funnel = struct {
    fds: [2]std.c.fd_t = undefined,
    lock: std.Thread.Mutex = undefined,
    marshal: *marshal_func = undefined,
    unmarshal: *unmarshal_func = undefined,

    pub fn init(marshal: *marshal_func, unmarshal: *unmarshal_func) funnel_errors!Funnel {
        var result: Funnel = undefined;
        const err = std.c.pipe2(&result.fds, std.c.O.NONBLOCK);
        try pipe_error(err);
        result.lock = std.Thread.Mutex{};
        result.marshal = marshal;
        result.unmarshal = unmarshal;
        return result;
    }

    pub fn readFd(self: *Funnel) std.c.fd_t {
        return self.fds[0];
    }
    pub fn writeFd(self: *Funnel) std.c.fd_t {
        return self.fds[1];
    }

    pub fn write(self: *Funnel, e: Event) funnel_errors!usize {
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            const buffer = self.marshal(e.payload);
            const len = std.mem.len(buffer);
            const n = std.c.fwrite(buffer, @sizeOf(u8), len, self.writeFd());
            return n;
        }
        return funnel_errors.would_block;
    }
    pub fn read(self: *Funnel, cb: funnel_callback) funnel_errors!usize {
        if (self.lock.tryLock()) {
            defer self.lock.unlock();

        }
        return 0;
    }
};

export fn funnel_init(fun: *Funnel) c_int {
    const err = std.c.pipe2(&fun.fds, std.c.O.NONBLOCK);
    if (err == -1) {
        return std.c._errno();
    }
    fun.lock = std.Thread.Mutex{};
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
