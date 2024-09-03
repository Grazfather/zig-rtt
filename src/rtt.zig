const std = @import("std");

pub const ChannelMode = enum(usize) {
    NoBlockSkip = 0,
    NoBlockTrim = 1,
    BlockIfFull = 2,
    _,
};

/// Header that indicates to the connected probe how many up/down channels are in use.
///
/// The RTT header is found based on the string "SEGGER RTT", so we need to avoid storing
/// the whole string in memory anywhere other than this header (otherwise host software
/// may choose the wrong location). Storing it reversed in the variable "init_str" and then
/// copying it over accomplishes this.
pub const Header = extern struct {
    id: [16]u8,
    max_up_channels: usize,
    max_down_channels: usize,

    pub fn init(self: *Header, comptime max_up_channels: usize, comptime max_down_channels: usize) void {
        self.max_up_channels = max_up_channels;
        self.max_down_channels = max_down_channels;

        const init_str = "\x00\x00\x00\x00\x00\x00TTR REGGES";

        // TODO: Memory barrier (DMB)
        for (0..init_str.len) |i| {
            self.id[i] = init_str[init_str.len - i - 1];
        }
        // TODO: Memory barrier (DMB)
    }
};

/// Represents a target -> host communication channel.
///
/// Implements a ring buffer of size - 1 bytes, as this implementation
/// does not fill up the buffer in order to avoid the problem of being unable to
/// distinguish between full and empty.
pub const UpChannel = extern struct {
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

    pub fn init(
        /// "Volatile to make sure that compiler cannot change the order of accesses to the control block" - TODO: Is this appropriate for init?
        self: *volatile UpChannel,
        name: [*:0]const u8,
        buffer: []u8,
        mode_: ChannelMode,
    ) void {
        self.name = name;
        self.size = buffer.len;
        self.flags = 0;

        // TODO: Copying code rather than calling self.setMode() to limit scope of *volatile
        self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);

        // "Set the buffer pointer last, because it is used to detect if the channel was initialized" - TODO: Is this accurate?
        self.buffer = buffer.ptr;
    }

    pub fn mode(self: *UpChannel) ChannelMode {
        return std.meta.intToEnum(ChannelMode, self.flags & 3) catch unreachable;
    }

    pub fn setMode(self: *UpChannel, mode_: ChannelMode) void {
        self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);
    }

    pub const WriteError = error{BadMode};
    pub const Writer = std.io.GenericWriter(*UpChannel, WriteError, write);

    /// Writes up to available space left in buffer for reading by probe, returning number of bytes
    /// written.
    pub fn writeUpTo(self: *UpChannel, bytes: []const u8) WriteError!usize {
        const count = @min(bytes.len, self.contiguousWriteable());
        var write_offset = self.write_offset;
        if (count > 0) {
            std.mem.copyForwards(u8, self.buffer[write_offset .. write_offset + count], bytes[0..count]);
            write_offset += count;
        } else {
            if (write_offset >= self.size)
                write_offset = 0;
        }

        // TODO: Memory barrier (DMB)
        // Force any data writes to complete before updating write offset in case of memory access reorder
        self.write_offset = write_offset;

        return count;
    }

    /// Blocks until all bytes are written to buffer
    pub fn writeBlocking(self: *UpChannel, bytes: []const u8) WriteError!usize {
        const count = bytes.len;
        var written: usize = 0;
        while (written != count) {
            written += try self.writeUpTo(bytes[written..]);
        }
        return count;
    }

    /// Behavior depends on up channel's mode, however write always returns
    /// the length of bytes indicating all bytes were "written"
    pub fn write(self: *UpChannel, bytes: []const u8) WriteError!usize {
        switch (self.mode()) {
            .NoBlockSkip => {
                if (bytes.len <= self.contiguousWriteable()) {
                    _ = try self.writeUpTo(bytes);
                }
            },
            .NoBlockTrim => {
                _ = try self.writeUpTo(bytes);
            },
            .BlockIfFull => {
                _ = try self.writeBlocking(bytes);
            },
            _ => return WriteError.BadMode,
        }
        return bytes.len;
    }

    pub fn writer(self: *UpChannel) Writer {
        return .{ .context = self };
    }

    fn contiguousWriteable(self: *UpChannel) usize {

        // The probe can change self.read_offset via memory modification at any time,
        // so must perform a volatile read on this value.
        const read_offset = @as(*volatile usize, @ptrCast(&self.read_offset)).*;

        const write_offset = self.write_offset;
        // TODO: Changed back to original Segger method for additional branch eval
        return if (read_offset <= write_offset)
            self.size - 1 - write_offset + read_offset
        else
            read_offset - write_offset - 1;
    }
};

/// Represents a host -> target communication channel.
///
/// Implements a ring buffer of size - 1 bytes, as this implementation
/// does not fill up the buffer in order to avoid the problem of being unable to
/// distinguish between full and empty.
pub const DownChannel = extern struct {
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

    pub fn init(
        /// "Volatile to make sure that compiler cannot change the order of accesses to the control block" - TODO: Is this appropriate for init?
        self: *volatile DownChannel,
        name: [*:0]const u8,
        buffer: []u8,
        mode_: ChannelMode,
    ) void {
        self.name = name;
        self.size = buffer.len;
        self.flags = 0;

        // TODO: Copying code rather than calling self.setMode() to limit scope of *volatile
        self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);

        // "Set the buffer pointer last, because it is used to detect if the channel was initialized" - TODO: Is this accurate?
        self.buffer = buffer.ptr;
    }

    pub fn mode(self: *DownChannel) ChannelMode {
        return std.meta.intToEnum(ChannelMode, self.mode & 3);
    }

    pub fn setMode(self: *DownChannel, mode_: ChannelMode) void {
        self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);
    }

    pub const ReadError = error{};
    pub const Reader = std.io.GenericReader(*DownChannel, ReadError, read);

    /// Reads a number of bytes from probe non-blocking.
    pub fn read(self: *DownChannel, bytes: []u8) ReadError!usize {

        // The probe can change self.write_offset via memory modification at any time,
        // so must perform a volatile read on this value.
        const write_offset = @as(*volatile usize, @ptrCast(&self.write_offset)).*;

        var bytes_read: usize = 0;
        // Read from current read position to wrap-around of buffer, first
        if (self.read_offset > write_offset) {
            const count = @min(self.size - self.read_offset, bytes.len);
            std.mem.copyForwards(u8, bytes[0..count], self.buffer[self.read_offset .. self.read_offset + count]);
            bytes_read += count;
            self.read_offset += count;

            // Handle wrap-around
            if (self.read_offset >= self.size) self.read_offset = 0;
        }

        const remaining_bytes = @min(write_offset - self.read_offset, bytes[bytes_read..].len);
        // Read remaining items of buffer
        if (remaining_bytes > 0) {
            std.mem.copyForwards(u8, bytes[bytes_read .. bytes_read + remaining_bytes], self.buffer[self.read_offset .. self.read_offset + remaining_bytes]);
            bytes_read += remaining_bytes;
            self.read_offset += remaining_bytes;
        }

        return bytes_read;
    }

    pub fn reader(self: *DownChannel) Reader {
        return .{ .context = self };
    }

    // TODO: Abstract to bytesAvailable() function
};

pub fn RTT(comptime num_up_channels: usize, comptime num_down_channels: usize) type {
    return extern struct {
        header: Header,
        up_channels: [num_up_channels]UpChannel,
        down_channels: [num_down_channels]DownChannel,
        buffers: [num_up_channels + num_down_channels][512]u8, // TODO: Configurable/seperated buffer sizes

        /// TODO: Can't currently put * volatile on @This() due to slice type errors, but it appears neccessary because:
        /// - This is trying to avoid the "SEGGER RTT\0..." string from being reordered and written before offsets are valid
        pub fn init(self: *@This()) void {
            comptime var i: usize = 0;
            inline while (i < num_up_channels) : (i += 1) {
                self.up_channels[i].init("Terminal", &self.buffers[i], .NoBlockSkip); // TODO: Configurable names/modes
            }
            i = 0;
            inline while (i < num_down_channels) : (i += 1) {
                self.down_channels[i].init("Terminal", &self.buffers[num_up_channels + i], .BlockIfFull); // TODO: Configurable names/modes
            }
            self.header.init(num_up_channels, num_down_channels);
        }
    };
}
