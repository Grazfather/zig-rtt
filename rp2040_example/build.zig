const std = @import("std");

const MicroZig = @import("microzig/build");
const rp2040 = @import("microzig/bsp/raspberrypi/rp2040");

pub fn build(b: *std.Build) void {
    const mz = MicroZig.init(b, .{});
    const optimize = b.standardOptimizeOption(.{});
    const firmware = mz.add_firmware(b, .{
        .name = "rtt_example",
        .target = rp2040.boards.raspberrypi.pico,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    const rtt_dep = b.dependency("rtt", .{}).module("rtt");
    firmware.add_app_import("rtt", rtt_dep, .{});

    mz.install_firmware(b, firmware, .{});
    mz.install_firmware(b, firmware, .{ .format = .elf });
}
