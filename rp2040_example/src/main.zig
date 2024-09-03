const std = @import("std");
const microzig = @import("microzig");
const rtt = @import("rtt");
const rp2040 = microzig.hal;
const time = rp2040.time;
const Pin = rp2040.gpio.Pin;

pub const microzig_options = .{
    .logFn = log,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_prefix = comptime "[{}.{:0>6}] " ++ level.asText();
    const prefix = comptime level_prefix ++ switch (scope) {
        .default => ": ",
        else => " (" ++ @tagName(scope) ++ "): ",
    };

    if (safe_to_use) {
        const current_time = time.get_time_since_boot();
        const seconds = current_time.to_us() / std.time.us_per_s;
        const microseconds = current_time.to_us() % std.time.us_per_s;
        rtt_instance.up_channels[0].writer().print(prefix ++ format ++ "\r\n", .{ seconds, microseconds } ++ args) catch {};
    }
}

fn blinkLed(led_gpio: *Pin) void {
    led_gpio.put(0);
    time.sleep_ms(500);
    led_gpio.put(1);
    time.sleep_ms(500);
}

const RttType = rtt.RTT(1, 1);
var rtt_instance: RttType = undefined;

// TODO: less hacky
var safe_to_use: bool = false;

const Error = error{BufferOverflow};
fn getLineBlocking(comptime max_line_size: usize, reader: anytype, writer: anytype) !void {
    var read_buffer: [max_line_size]u8 = undefined;
    var bytes_read: usize = 0;
    while (true) {
        bytes_read += try reader.read(read_buffer[bytes_read..]);
        if (bytes_read > 0) {
            if (std.mem.indexOf(u8, read_buffer[0..bytes_read], "\r\n")) |line_end| {
                return writer.writeAll(read_buffer[0..line_end]);
            }
        }
        if (bytes_read == max_line_size) {
            return Error.BufferOverflow;
        }
    }
}

pub fn main() !void {

    // Don't forget to bring a blinky!
    var led_gpio = rp2040.gpio.num(25);
    led_gpio.set_direction(.out);
    led_gpio.set_function(.sio);
    led_gpio.put(1);

    rtt_instance.init();
    safe_to_use = true;

    std.log.info("Waiting for line:", .{});
    const reader = rtt_instance.down_channels[0].reader();

    while (true) {
        const max_line_len = 10;
        var line_buffer = try std.BoundedArray(u8, max_line_len).init(0);
        try getLineBlocking(max_line_len, reader, line_buffer.writer());
        std.log.info("Got a line: \"{s}\"", .{line_buffer.constSlice()});
        std.log.info("...take a blink as a reward", .{});
        blinkLed(&led_gpio);
    }
}
