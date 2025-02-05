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

/// enum values for C interop
pub const funnel_notifs_t = enum(c_int) {
    SUCCESS = 0,
    WOULD_BLOCK = 1,
    CLOSED = 2,
};

/// Marshal function signature.
pub const marshal_func = fn (*anyopaque, [*]u8, usize) callconv(.C) c_int;
/// Unmarshal function signature.
pub const unmarshal_func = fn ([*]const u8) callconv(.C) ?*anyopaque;
/// Size function signature.
pub const size_func = fn () callconv(.C) usize;
/// Funnel callback function signature.
pub const funnel_callback = fn (*anyopaque) callconv(.C) void;

/// Convert Zig error to C error.
pub fn error_to_c_error(e: funnel_errors) c_int {
    return switch (e) {
        funnel_errors.pipe_too_many_descriptors => @intFromEnum(std.os.linux.E.MFILE),
        funnel_errors.pipe_system_table_full => @intFromEnum(std.os.linux.E.NFILE),
        funnel_errors.pipe_invalid_fds_buffer => @intFromEnum(std.os.linux.E.FAULT),
        funnel_errors.pipe_invalid_flags => @intFromEnum(std.os.linux.E.INVAL),
        funnel_errors.would_block => @intFromEnum(funnel_notifs_t.WOULD_BLOCK),
        funnel_errors.closed => @intFromEnum(funnel_notifs_t.CLOSED),
    };
}

/// returns the proper funnel_error type for the given POSIX error.
fn pipe_error(err: c_int) !void {
    if (err == -1) {
        const e = std.c._errno();
        if (e.* == @intFromEnum(std.os.linux.E.MFILE)) return funnel_errors.pipe_too_many_descriptors;
        if (e.* == @intFromEnum(std.os.linux.E.NFILE)) return funnel_errors.pipe_system_table_full;
        if (e.* == @intFromEnum(std.os.linux.E.FAULT)) return funnel_errors.pipe_invalid_fds_buffer;
        if (e.* == @intFromEnum(std.os.linux.E.INVAL)) return funnel_errors.pipe_invalid_flags;
    }
    return;
}

/// Event structure to be used with the EventMarshaller.
pub const Event = extern struct {
    // Payload
    payload: *anyopaque,
};

/// Structure to contain all functionality to handle writing and reading
/// of events.
/// Currently the marshaller does not support dynamic payload size.
pub const EventMarshaller = extern struct {
    /// Marshal events.
    marshal: ?*const marshal_func = undefined,
    /// Unmarshal events.
    unmarshal: ?*const unmarshal_func = undefined,
    /// Size of event payload.
    size: ?*const size_func = undefined,
};

/// Structure to setup and manage writing and reading events between callers and receivers.
/// Meant to only be used with one reader but multiple writers.
pub const Funnel = struct {
    alloc: std.mem.Allocator = undefined,
    lock: std.Thread.Mutex = undefined,
    buffer: []u8 = undefined,
    fds: [2]std.c.fd_t = undefined,
    marshaller: EventMarshaller = undefined,
    closed: bool = false,

    /// Initialize with an event marshaller.
    pub fn init(alloc: std.mem.Allocator, marshaller: EventMarshaller) !Funnel {
        var result: Funnel = Funnel{};
        result.alloc = alloc;
        const options = std.c.O{
            .NONBLOCK = true,
        };
        const err = std.c.pipe2(&result.fds, options);
        try pipe_error(err);
        result.lock = std.Thread.Mutex{};
        result.marshaller = marshaller;
        if (result.marshaller.size) |size_fn| {
            result.buffer = try result.alloc.alloc(u8, size_fn());
        }
        result.closed = false;
        return result;
    }

    /// Create an allocated Funnel structure with an event marshaller.
    pub fn create(alloc: std.mem.Allocator, marshaller: EventMarshaller) !*Funnel {
        var result: *Funnel = try alloc.create(Funnel);
        errdefer alloc.destroy(result);
        result.alloc = alloc;
        const options = std.c.O{
            .NONBLOCK = true,
        };
        const err = std.c.pipe2(&result.fds, options);
        try pipe_error(err);
        result.lock = std.Thread.Mutex{};
        result.marshaller = marshaller;
        if (result.marshaller.size) |size_fn| {
            result.buffer = try result.alloc.alloc(u8, size_fn());
        }
        result.closed = false;
        return result;
    }

    /// Get the read pipe.
    fn readFd(self: *Funnel) std.c.fd_t {
        return self.fds[0];
    }
    /// Get the write pipe.
    fn writeFd(self: *Funnel) std.c.fd_t {
        return self.fds[1];
    }

    /// Write the given event to the reader.
    /// Returns would_block if a lock could not be acquired.
    pub fn write(self: *Funnel, e: Event) funnel_errors!isize {
        if (self.closed) return funnel_errors.closed;
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            var n: isize = 0;
            const len: usize = self.buffer.len;
            if (self.marshaller.marshal) |marshal_fn| {
                const ret = marshal_fn(e.payload, self.buffer.ptr, self.buffer.len);
                if (ret == 0) {
                    n = std.c.write(self.writeFd(), self.buffer.ptr, len);
                }
            }
            return n;
        }
        return funnel_errors.would_block;
    }

    /// Read the next event off the pipe and send to the given callback function.
    /// Returns would_block if a lock could not be acquired.
    pub fn read(self: *Funnel, cb: *const funnel_callback) funnel_errors!isize {
        if (self.closed) return funnel_errors.closed;
        var result_n: isize = 0;
        if (self.lock.tryLock()) {
            defer self.lock.unlock();
            result_n = std.c.read(self.readFd(), self.buffer.ptr, self.buffer.len);
            if (result_n > 0) {
                if (self.marshaller.unmarshal) |unmarshal_fn| {
                    const event = unmarshal_fn(self.buffer.ptr);
                    if (event) |e| {
                        cb(e);
                    }
                }
            }
            return result_n;
        }
        return funnel_errors.would_block;
    }

    /// Deinitialize internal data.
    pub fn deinit(self: *Funnel) void {
        if (self.closed) return;
        self.lock.lock();
        defer self.lock.unlock();
        self.alloc.free(self.buffer);
        _ = std.c.close(self.readFd());
        _ = std.c.close(self.writeFd());
        self.closed = true;
    }
};

/// Structure to use for external C use.
pub const funnel_t = extern struct {
    __internal: *anyopaque,
};

/// Initialize a funnel object to be used in external C program.
/// @param fun The C funnel structure.
/// @param marshaller The event marshaller structure.
/// @return 0 for success, anything else error.
pub export fn funnel_init(fun: *funnel_t, marshaller: EventMarshaller) c_int {
    const result: *Funnel = Funnel.create(std.heap.c_allocator, marshaller) catch |err| {
        if (@TypeOf(err) == funnel_errors) {
            return error_to_c_error(err);
        }
        return -1;
    };
    fun.__internal = @ptrCast(result);
    return 0;
}

/// Structure to contain result info for funnel C functions.
pub const funnel_result = extern struct {
    /// C enum result.
    result: c_int = @intFromEnum(funnel_notifs_t.SUCCESS),
    /// Size of bytes written/read.
    len: isize = 0,
};

/// Write an event to the funnel structure.
/// @param fun The funnel structure.
/// @param e The event payload to write.
/// @return The result to contain SUCCESS, WOULD_BLOCK, or error info.
pub export fn funnel_write(fun: *funnel_t, e: Event) funnel_result {
    var result = funnel_result{};
    var n: isize = 0;
    const rawValue: *Funnel = @alignCast(@ptrCast(fun.__internal));
    if (rawValue.write(e)) |val| {
        n = val;
    } else |err| {
        result.result = error_to_c_error(err);
    }
    result.len = n;
    return result;
}

/// Read the next event from the funnel structure.
/// @param fun The funnel structure.
/// @param cb The callback function to read the next event into.
/// @return The result to contain SUCCESS, WOULD_BLOCK, or error info.
pub export fn funnel_read(fun: *funnel_t, cb: *const funnel_callback) funnel_result {
    var result = funnel_result{};
    var n: isize = 0;
    const rawValue: *Funnel = @alignCast(@ptrCast(fun.__internal));
    if (rawValue.read(cb)) |val| {
        n = val;
    } else |err| {
        result.result = error_to_c_error(err);
    }
    result.len = n;
    return result;
}

/// Free the internal data of the given funnel structure.
/// @param fun The funnel structure.
pub export fn funnel_free(fun: *funnel_t) void {
    const rawValue: *Funnel = @alignCast(@ptrCast(fun.__internal));
    const alloc = rawValue.alloc;
    defer alloc.destroy(rawValue);
    rawValue.deinit();
}
