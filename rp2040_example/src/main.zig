const std = @import("std");
const microzig = @import("microzig");
const rtt = @import("rtt");
const rp2040 = microzig.hal;
const time = rp2040.time;
const Pin = rp2040.gpio.Pin;

pub const microzig_options = .{
    .logFn = rp2040.uart.log,
};

const gpio = rp2040.gpio;
const uart = rp2040.uart.num(1);
const baud_rate = 115200;
const uart_tx_pin = gpio.num(8);
const uart_rx_pin = gpio.num(9);

fn blinkLed(led_gpio: *Pin) void {
    led_gpio.put(0);
    time.sleep_ms(500);
    led_gpio.put(1);
    time.sleep_ms(500);
}

var pretend_locked: bool = false;

const Context = *bool;

fn pretendLock(context: Context) void {
    context.* = true;
}

fn pretendUnlock(context: Context) void {
    context.* = false;
}

var pretend_lock: rtt.GenericLock(Context, pretendLock, pretendUnlock) = .{
    .context = &pretend_locked,
};

// Configure RTT with specific sizes/names for up and down channels (2 of each) as
// well as a custom locking routine and specific linker placement.
const rtt_instance = rtt.RTT(.{
    .up_channels = &.{
        .{ .name = "Terminal", .mode = .NoBlockSkip, .buffer_size = 128 },
        .{ .name = "Up2", .mode = .NoBlockSkip, .buffer_size = 256 },
    },
    .down_channels = &.{
        .{ .name = "Terminal", .mode = .BlockIfFull, .buffer_size = 512 },
        .{ .name = "Down2", .mode = .BlockIfFull, .buffer_size = 1024 },
    },
    .exclusive_access = pretend_lock.any(),
    .linker_section = ".rtt_cb",
});

// Configure RTT with all default settings:
// const rtt_instance = rtt.RTT(.{});

// Configure RTT with default settings but disable exclusive access protection
// const rtt_instance = rtt.RTT(.{ .exclusive_access = null });

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
    uart.apply(.{
        .baud_rate = baud_rate,
        .tx_pin = uart_tx_pin,
        .rx_pin = uart_rx_pin,
        .clock_config = rp2040.clock_config,
    });
    rp2040.uart.init_logger(uart);

    // Don't forget to bring a blinky!
    var led_gpio = rp2040.gpio.num(25);
    led_gpio.set_direction(.out);
    led_gpio.set_function(.sio);
    led_gpio.put(1);

    rtt_instance.init();

    const reader = rtt_instance.reader(0);
    const writer = rtt_instance.writer(0);

    while (true) {
        const max_line_len = 1024;
        var line_buffer = try std.BoundedArray(u8, max_line_len).init(0);
        try getLineBlocking(max_line_len, reader, line_buffer.writer());
        std.log.info("Got a line: \"{s}\"", .{line_buffer.constSlice()});
        std.log.info("...take an RTT blink as a reward", .{});
        _ = try writer.write("BLINK\n");
        blinkLed(&led_gpio);
    }
}
