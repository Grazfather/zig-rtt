const std = @import("std");

// const mz_main = @import("microzig");
const MicroZig = @import("microzig/build");
const rp2040 = @import("microzig/bsp/raspberrypi/rp2040");

pub fn build(b: *std.Build) void {
    const mz = MicroZig.init(b, .{});
    const optimize = b.standardOptimizeOption(.{});
    const firmware = mz.add_firmware(b, .{
        .name = "selftest",
        .target = rp2040.boards.raspberrypi.pico,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });

    const rtt_dep = b.dependency("rtt", .{}).module("rtt");
    firmware.add_app_import("rtt", rtt_dep, .{});

    // `install_firmware()` is the MicroZig pendant to `Build.installArtifact()`
    // and allows installing the firmware as a typical firmware file.
    //
    // This will also install into `$prefix/firmware` instead of `$prefix/bin`.
    mz.install_firmware(b, firmware, .{});

    // For debugging, we also always install the firmware as an ELF file
    mz.install_firmware(b, firmware, .{ .format = .elf });
}
