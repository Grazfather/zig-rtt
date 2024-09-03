const std = @import("std");
const microzig = @import("microzig");
const rtt = @import("rtt");
const rp2040 = microzig.hal;
const time = rp2040.time;
const Pin = rp2040.gpio.Pin;

// pub const microzig_options = .{
//     .logFn = log,
// };
// const test_logger = std.log.scoped(.SelfTest);

fn blinkLed(led_gpio: *Pin) void {
    led_gpio.put(0);
    time.sleep_ms(500);
    led_gpio.put(1);
    time.sleep_ms(500);
}

const RttType = rtt.Rtt(1, 1);

var rtt_block: RttType = undefined;
pub fn main() !void {
    // Don't forget to bring a blinky!
    var led_gpio = rp2040.gpio.num(25);
    led_gpio.set_direction(.out);
    led_gpio.set_function(.sio);
    led_gpio.put(1);

    rtt_block.init();
    const writer = rtt_block.up_channels[0].writer();

    // End and just idle forever
    while (true) {
        try writer.print("Blink from RTT!\n", .{});
        blinkLed(&led_gpio);
    }
}
