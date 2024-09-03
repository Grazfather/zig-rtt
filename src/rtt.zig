const std = @import("std");

pub const ChannelMode = enum(usize) {
    NoBlockSkip = 0,
    NoBlockTrim = 1,
    BlockIfFull = 2,
    _,
};

pub const RttHeader = extern struct {
    id: [16]u8,
    max_up_channels: usize,
    max_down_channels: usize,

    pub fn init(self: *RttHeader, comptime max_up_channels: usize, comptime max_down_channels: usize) void {
        self.max_up_channels = max_up_channels;
        self.max_down_channels = max_down_channels;

        // The RTT header is found based on the string "SEGGER RTT", so we need to avoid having the whole string
        // in memory anywhere so the correct location is found. Storing it reversed and then copying it over accomplishes this.
        const init_str = "\x00\x00\x00\x00\x00\x00TTR REGGES";
        for (0..init_str.len) |i| {
            self.id[i] = init_str[init_str.len - i - 1];
        }
    }
};

pub const RttChannel = extern struct {
    name: [*]const u8,
    buffer: [*]u8,
    size: usize,
    write_: usize,
    read: usize,
    flags: usize,

    pub fn init(
        self: *RttChannel,
        name: [*:0]const u8,
        buffer: []u8,
        mode_: ChannelMode,
    ) void {
        self.name = name;
        self.size = buffer.len;
        self.flags = 0;

        self.setMode(mode_);

        // set the buffer pointer as last, because it is used to detect if the channel was initialized
        self.buffer = buffer.ptr;
    }

    pub fn mode(self: *RttChannel) ChannelMode {
        return std.meta.intToEnum(ChannelMode, self.mode & 3);
    }

    pub fn setMode(self: *RttChannel, mode_: ChannelMode) void {
        self.flags = (self.flags & ~@as(usize, 3)) | @intFromEnum(mode_);
    }

    pub const WriteError = error{};
    pub const Writer = std.io.Writer(*RttChannel, WriteError, write);

    pub fn write(self: *RttChannel, bytes: []const u8) WriteError!usize {
        const count = @min(bytes.len, self.contiguousWritable());
        if (count > 0) {
            std.mem.copyForwards(u8, self.buffer[self.write_ .. self.write_ + count], bytes[0..count]);
            self.write_ += count;
        } else {
            if (self.write_ >= self.size)
                self.write_ = 0;
        }

        return count;
    }

    pub fn writer(self: *RttChannel) Writer {
        return .{ .context = self };
    }

    fn contiguousWritable(self: *RttChannel) usize {
        const read = self.read;
        return if (read > self.write_)
            read - self.write_ - 1
        else if (read == 0)
            self.size - self.write_ - 1
        else
            self.size - self.write_;
    }
};

// TODO: configurable channels
pub fn Rtt(comptime num_up_channels: usize, comptime num_down_channels: usize) type {
    return extern struct {
        header: RttHeader,
        up_channels: [num_up_channels]RttChannel,
        down_channels: [num_down_channels]RttChannel,
        buffers: [num_up_channels + num_down_channels][1024]u8, // TODO: Configurable/seperated buffer sizes

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
