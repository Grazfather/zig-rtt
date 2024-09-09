const std = @import("std");

/// Header that indicates to the connected probe how many up/down channels are in use.
///
/// The RTT header is found based on the string "SEGGER RTT", so we need to avoid storing
/// the whole string in memory anywhere other than this header (otherwise host software
/// may choose the wrong location). Storing it reversed in the variable "init_str" and then
/// copying it over accomplishes this.
const Header = extern struct {
    id: [16]u8,
    max_up_channels: usize,
    max_down_channels: usize,

    pub fn init(self: *Header, comptime max_up_channels: usize, comptime max_down_channels: usize) void {
        self.max_up_channels = max_up_channels;
        self.max_down_channels = max_down_channels;

        const init_str = "\x00\x00\x00\x00\x00\x00TTR REGGES";

        // Ensure no memory reordering can occur and all accesses are finished before
        // marking block "valid" and writing header string. This prevents the JLINK
        // from finding a "valid" block while offets/pointers aren't yet valid.
        @fence(std.builtin.AtomicOrder.seq_cst);
        for (0..init_str.len) |i| {
            self.id[i] = init_str[init_str.len - i - 1];
        }
        @fence(std.builtin.AtomicOrder.seq_cst);
    }
};

pub const channel = struct {
    pub const Mode = enum(usize) {
        NoBlockSkip = 0,
        NoBlockTrim = 1,
        BlockIfFull = 2,
        _,
    };

    pub const Config = struct {
        name: [*:0]const u8,
        buffer_size: usize,
        mode: Mode,
    };

    /// Represents a target -> host communication channel.
    ///
    /// Implements a ring buffer of size - 1 bytes, as this implementation
    /// does not fill up the buffer in order to avoid the problem of being unable to
    /// distinguish between full and empty.
    fn Up(comptime thread_safety_: ThreadSafety) type {
        return extern struct {
            /// Name is optional and is not required by the spec. Standard names so far are:
            /// "Terminal", "SysView", "J-Scope_t4i4"
            name: [*]const u8,

            buffer: [*]u8,

            /// Note from above actual buffer size is size - 1 bytes
            size: usize,

            write_offset: usize,
            read_offset: usize,

            /// Contains configuration flags. Flags[31:24] are used for validity check and must be zero.
            /// Flags[23:2] are reserved for future use. Flags[1:0] = RTT operating mode.
            flags: usize,

            const thread_safety = thread_safety_;
            const Self = @This();

            fn init(
                self: *Self,
                name: [*:0]const u8,
                buffer: []u8,
                mode_: Mode,
            ) void {
                self.name = name;
                self.size = buffer.len;
                self.setMode(mode_);

                // Ensure buffer pointer is set last and can't be reordered
                @fence(std.builtin.AtomicOrder.seq_cst);
                self.buffer = buffer.ptr;
            }

            fn mode(self: *Self) Mode {
                return std.meta.intToEnum(Mode, self.flags & 3) catch unreachable;
            }

            fn setMode(self: *Self, mode_: Mode) void {
                self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);
            }

            const WriteError = error{};
            const Writer = std.io.GenericWriter(*Self, WriteError, write);

            /// Writes up to available space left in buffer for reading by probe, returning number of bytes
            /// written.
            fn writeAvailable(self: *Self, bytes: []const u8) WriteError!usize {

                // The probe can change self.read_offset via memory modification at any time,
                // so must perform a volatile read on this value.
                const read_offset = @as(*volatile usize, @ptrCast(&self.read_offset)).*;
                var write_offset = self.write_offset;
                var bytes_written: usize = 0;
                // Write from current write position to wrap-around of buffer first
                if (write_offset >= read_offset) {
                    const count = @min(self.size - write_offset, bytes.len);
                    std.mem.copyForwards(
                        u8,
                        self.buffer[write_offset .. write_offset + count],
                        bytes[0..count],
                    );
                    bytes_written += count;
                    write_offset += count;

                    // Handle wrap-around
                    if (write_offset >= self.size) write_offset = 0;
                }

                // We've now either wrapped around or were wrapped around to begin with
                if (write_offset < read_offset) {
                    const remaining_bytes = @min(read_offset - write_offset - 1, bytes[bytes_written..].len);
                    // Read remaining items of buffer
                    if (remaining_bytes > 0) {
                        std.mem.copyForwards(
                            u8,
                            self.buffer[write_offset .. write_offset + remaining_bytes],
                            bytes[bytes_written .. bytes_written + remaining_bytes],
                        );
                        bytes_written += remaining_bytes;
                        write_offset += remaining_bytes;
                    }
                }

                // Force data write to be complete before writing the <WrOff>, in case CPU
                // is allowed to change the order of memory accesses
                @fence(std.builtin.AtomicOrder.seq_cst);
                self.write_offset = write_offset;
                return bytes_written;
            }

            /// Blocks until all bytes are written to buffer
            fn writeBlocking(self: *Self, bytes: []const u8) WriteError!usize {
                const count = bytes.len;
                var written: usize = 0;
                while (written != count) {
                    written += try self.writeAvailable(bytes[written..]);
                }
                return count;
            }

            /// Behavior depends on up channel's mode, however write always returns
            /// the length of bytes indicating all bytes were "written" even if they were
            /// skipped. Dropped data due to a full buffer is not considered an error.
            fn write(self: *Self, bytes: []const u8) WriteError!usize {
                thread_safety.lock_fn();
                switch (self.mode()) {
                    .NoBlockSkip => {
                        if (bytes.len <= self.availableSpace()) {
                            _ = try self.writeAvailable(bytes);
                        }
                    },
                    .NoBlockTrim => {
                        _ = try self.writeAvailable(bytes);
                    },
                    .BlockIfFull => {
                        _ = try self.writeBlocking(bytes);
                    },
                    _ => unreachable,
                }
                thread_safety.unlock_fn();
                return bytes.len;
            }

            fn writer(self: *Self) Writer {
                return .{ .context = self };
            }

            /// Available space in the ring buffer for writing, including wrap-around
            fn availableSpace(self: *Self) usize {

                // The probe can change self.read_offset via memory modification at any time,
                // so must perform a volatile read on this value.
                const read_offset = @as(*volatile usize, @ptrCast(&self.read_offset)).*;

                if (read_offset <= self.write_offset) {
                    return self.size - 1 - self.write_offset + read_offset;
                } else {
                    return read_offset - self.write_offset - 1;
                }
            }
        };
    }

    /// Represents a host -> target communication channel.
    ///
    /// Implements a ring buffer of size - 1 bytes, as this implementation
    /// does not fill up the buffer in order to avoid the problem of being unable to
    /// distinguish between full and empty.
    fn Down(comptime thread_safety_: ThreadSafety) type {
        return extern struct {
            /// Name is optional and is not required by the spec. Standard names so far are:
            /// "Terminal", "SysView", "J-Scope_t4i4"
            name: [*]const u8,

            buffer: [*]u8,

            /// Note from above actual buffer size is size - 1 bytes
            size: usize,

            write_offset: usize,
            read_offset: usize,

            /// Contains configuration flags. Flags[31:24] are used for validity check and must be zero.
            /// Flags[23:2] are reserved for future use. Flags[1:0] = RTT operating mode.
            flags: usize,

            const Self = @This();
            const thread_safety = thread_safety_;

            pub fn init(
                self: *Self,
                name: [*:0]const u8,
                buffer: []u8,
                mode_: Mode,
            ) void {
                self.name = name;
                self.size = buffer.len;
                self.setMode(mode_);

                // Ensure buffer pointer is set last and can't be reordered
                @fence(std.builtin.AtomicOrder.seq_cst);
                self.buffer = buffer.ptr;
            }

            pub fn mode(self: *Self) Mode {
                return std.meta.intToEnum(Mode, self.mode & 3);
            }

            pub fn setMode(self: *Self, mode_: Mode) void {
                self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);
            }

            pub const ReadError = error{};
            pub const Reader = std.io.GenericReader(*Self, ReadError, readAvailable);

            /// Reads up to a number of bytes from probe non-blocking. Reading less than the requested number of bytes
            /// is not an error.
            ///
            /// TODO: Does the channel's mode actually matter here?
            pub fn readAvailable(self: *Self, bytes: []u8) ReadError!usize {
                thread_safety.lock_fn();

                // The probe can change self.write_offset via memory modification at any time,
                // so must perform a volatile read on this value.
                const write_offset = @as(*volatile usize, @ptrCast(&self.write_offset)).*;
                var read_offset = self.read_offset;

                var bytes_read: usize = 0;
                // Read from current read position to wrap-around of buffer, first
                if (read_offset > write_offset) {
                    const count = @min(self.size - read_offset, bytes.len);
                    std.mem.copyForwards(u8, bytes[0..count], self.buffer[read_offset .. read_offset + count]);
                    bytes_read += count;
                    read_offset += count;

                    // Handle wrap-around
                    if (read_offset >= self.size) read_offset = 0;
                }

                // We've now either wrapped around or were wrapped around to begin with
                if (read_offset < write_offset) {
                    const remaining_bytes = @min(write_offset - read_offset, bytes[bytes_read..].len);
                    // Read remaining items of buffer
                    if (remaining_bytes > 0) {
                        std.mem.copyForwards(u8, bytes[bytes_read .. bytes_read + remaining_bytes], self.buffer[read_offset .. read_offset + remaining_bytes]);
                        bytes_read += remaining_bytes;
                        read_offset += remaining_bytes;
                    }
                }

                // Force data write to be complete before writing the read_offset, in case CPU
                // is allowed to change the order of memory accesses
                @fence(std.builtin.AtomicOrder.seq_cst);
                self.read_offset = read_offset;

                thread_safety.unlock_fn();

                return bytes_read;
            }

            pub fn reader(self: *Self) Reader {
                return .{ .context = self };
            }

            /// Number of bytes written from probe in ring buffer.
            pub fn bytesAvailable(self: *Self) usize {

                // The probe can change self.write_offset via memory modification at any time,
                // so must perform a volatile read on this value.
                const write_offset = @as(*volatile usize, @ptrCast(&self.write_offset)).*;
                if (self.read_offset > write_offset) {
                    return self.size - self.read_offset + write_offset;
                } else {
                    return write_offset - self.read_offset;
                }
            }
        };
    }
};
/// Constructs a struct type where each field is a u8 array of size specified by channel config.
///
/// Fields follow the naming convention "up_buffer_N" for up channels, and "down_buffer_N" for down channels.
fn BuildBufferStorageType(comptime up_channels: []const channel.Config, comptime down_channels: []const channel.Config) type {
    const fields: []const std.builtin.Type.StructField = comptime v: {
        var fields_temp: [up_channels.len + down_channels.len]std.builtin.Type.StructField = undefined;
        for (up_channels, 0..) |up_cfg, idx| {
            const buffer_type = [up_cfg.buffer_size]u8;
            fields_temp[idx] = .{
                .name = std.fmt.comptimePrint("up_buffer_{d}", .{idx}),
                .type = buffer_type,
                .is_comptime = false,
                .alignment = @alignOf(buffer_type),
                .default_value = null,
            };
        }
        for (down_channels, 0..) |down_cfg, idx| {
            const buffer_type = [down_cfg.buffer_size]u8;
            fields_temp[up_channels.len + idx] = .{
                .name = std.fmt.comptimePrint("down_buffer_{d}", .{idx}),
                .type = buffer_type,
                .is_comptime = false,
                .alignment = @alignOf(buffer_type),
                .default_value = null,
            };
        }
        break :v &fields_temp;
    };

    return @Type(.{
        .Struct = .{
            .layout = .@"extern",
            .fields = fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

/// Creates a control block struct for the given channel configs. Buffer storage is also contained within this struct, although
/// per the RTT spec it doesn't have to be.
fn ControlBlock(comptime up_channels: []const channel.Config, comptime down_channels: []const channel.Config, comptime thread_safety: ThreadSafety) type {
    if (up_channels.len == 0 or down_channels.len == 0) {
        @compileError("Must have at least 1 up and down channel configured");
    }

    const BufferContainerType = BuildBufferStorageType(up_channels, down_channels);
    return extern struct {
        header: Header,
        up_channels: [up_channels.len]channel.Up(thread_safety),
        down_channels: [down_channels.len]channel.Down(thread_safety),
        buffers: BufferContainerType,

        pub fn init(self: *@This()) void {
            comptime var i: usize = 0;

            inline while (i < up_channels.len) : (i += 1) {
                self.up_channels[i].init(
                    up_channels[i].name,
                    &@field(self.buffers, std.fmt.comptimePrint("up_buffer_{d}", .{i})),
                    up_channels[i].mode,
                );
            }
            i = 0;
            inline while (i < down_channels.len) : (i += 1) {
                self.down_channels[i].init(
                    down_channels[i].name,
                    &@field(self.buffers, std.fmt.comptimePrint("down_buffer_{d}", .{i})),
                    down_channels[i].mode,
                );
            }
            // Prevent compiler from re-ordering header init function as it must come last
            @fence(std.builtin.AtomicOrder.seq_cst);
            self.header.init(up_channels.len, down_channels.len);
        }
    };
}

pub const ThreadSafety = struct {
    lock_fn: fn () void,
    unlock_fn: fn () void,
};

fn defaultLock() void {}
fn defaultUnlock() void {}

fn emptyLock() void {}
fn emptyUnlock() void {}

pub const Config = struct {
    up_channels: []const channel.Config = &[_]channel.Config{.{ .name = "Terminal", .buffer_size = 256, .mode = .NoBlockSkip }},
    down_channels: []const channel.Config = &[_]channel.Config{.{ .name = "Terminal", .buffer_size = 256, .mode = .BlockIfFull }},
    thread_safety: ?ThreadSafety = .{ .lock_fn = defaultLock, .unlock_fn = defaultUnlock },
    linker_section: ?[]const u8 = null,
};

/// Creates an RTT namespace given the compile time configuration with functions for writing/reading from RTT channels.
pub fn RTT(comptime config: Config) type {
    return struct {
        const thread_safety = config.thread_safety orelse .{ .lock_fn = emptyLock, .unlock_fn = emptyUnlock };
        var control_block: ControlBlock(
            config.up_channels,
            config.down_channels,
            thread_safety,
        ) = undefined; // TODO: Place at specific linker section

        comptime {
            if (config.linker_section) |section| @export(control_block, .{
                .name = "RttControlBlock",
                .section = section,
            });
        }

        /// Initialize RTT, must be called prior to calling any other API functions
        pub fn init() void {
            control_block.init();
        }

        pub const WriteError = channel.Up(thread_safety).WriteError;
        pub const Writer = channel.Up(thread_safety).Writer;

        pub fn write(comptime channel_number: usize, bytes: []const u8) WriteError!usize {
            comptime {
                if (channel_number >= config.up_channels.len) @compileError(std.fmt.comptimePrint("Channel number {d} exceeds max up channel number of {d}", .{ channel_number, config.up_channels.len - 1 }));
            }
            return control_block.up_channels[channel_number].write(bytes);
        }

        pub fn writer(comptime channel_number: usize) Writer {
            comptime {
                if (channel_number >= config.up_channels.len) @compileError(std.fmt.comptimePrint("Channel number {d} exceeds max up channel number of {d}", .{ channel_number, config.up_channels.len - 1 }));
            }
            return control_block.up_channels[channel_number].writer();
        }

        pub const ReadError = channel.Down(thread_safety).ReadError;
        pub const Reader = channel.Down(thread_safety).Reader;

        pub fn read(comptime channel_number: usize, bytes: []u8) ReadError!usize {
            comptime {
                if (channel_number >= config.down_channels.len) @compileError(std.fmt.comptimePrint("Channel number {d} exceeds max down channel number of {d}", .{ channel_number, config.down_channels.len - 1 }));
            }
            return control_block.down_channels[channel_number].readAvailable(bytes);
        }

        pub fn reader(comptime channel_number: usize) Reader {
            comptime {
                if (channel_number >= config.down_channels.len) @compileError(std.fmt.comptimePrint("Channel number {d} exceeds max down channel number of {d}", .{ channel_number, config.down_channels.len - 1 }));
            }
            return control_block.down_channels[channel_number].reader();
        }
    };
}
