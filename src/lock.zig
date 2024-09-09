const std = @import("std");
const builtin = @import("builtin");

/// A struct that provides exclusive access to RTT functions.
pub const Lock = struct {
    context: *anyopaque,

    /// Called before any write/read operations
    lockFn: fn (context: *anyopaque) void,

    /// Called after any write/read operations
    unlockFn: fn (context: *anyopaque) void,
};

/// Provides the same locking mechanism as included by the original RTT code.
///
/// The default lock behavior when none is provided explicitly.
pub const default = struct {
    var ctx: Context = undefined;

    const Context = struct { isr_reg_value: usize };

    const ArmV6mV8m = struct {
        fn lock(context: *anyopaque) void {
            const lock_ctx: *Context = @alignCast(@ptrCast(context));
            var val: usize = undefined;
            asm volatile (
                \\mrs   %[val], primask
                \\movs  r1, #1
                \\msr   primask, r1
                : [val] "=r" (val),
                :
                : "r1", "cc"
            );
            lock_ctx.isr_reg_value = val;
        }

        fn unlock(context: *anyopaque) void {
            const lock_ctx: *Context = @alignCast(@ptrCast(context));
            const val = lock_ctx.isr_reg_value;
            asm volatile ("msr   primask, %[val]"
                :
                : [val] "r" (val),
            );
        }
    };

    const ArmV7mV7emV8mMain = struct {
        const MAX_ISR_PRIORITY = 0x20;

        fn lock(context: *anyopaque) void {
            const lock_ctx: *Context = @alignCast(@ptrCast(context));
            var val: usize = undefined;
            asm volatile (
                \\mrs   %[val], basepri
                \\movs  r1, %[MAX_ISR_PRIORITY]
                \\msr   basepri, r1
                : [val] "=r" (val),
                : [MAX_ISR_PRIORITY] "i" (MAX_ISR_PRIORITY),
                : "r1", "cc"
            );
            lock_ctx.isr_reg_value = val;
        }

        fn unlock(context: *anyopaque) void {
            const lock_ctx: *Context = @alignCast(@ptrCast(context));
            const val = lock_ctx.isr_reg_value;
            asm volatile ("msr   basepri, %[val]"
                :
                : [val] "r" (val),
            );
        }
    };

    const ArmV7aV7r = struct {
        fn lock(context: *anyopaque) void {
            const lock_ctx: *Context = @alignCast(@ptrCast(context));
            var val: usize = undefined;
            asm volatile (
                \\mrs   r1, CPSR
                \\mrs   %[val], r1
                \\orr r1, r1, #0xC0
                \\msr CPSR_C, r1
                : [val] "=r" (val),
                :
                : "r1", "cc"
            );
            lock_ctx.isr_reg_value = val;
        }

        fn unlock(context: *anyopaque) void {
            const lock_ctx: *Context = @alignCast(@ptrCast(context));
            const val = lock_ctx.isr_reg_value;
            asm volatile (
                \\mov r0, %[val]
                \\mrs r1, CPSR
                \\bic r1, r1, #0xC0
                \\and r0, r0, #0xC0
                \\orr r1, r1, r0
                \\msr CPSR_C, r1
                :
                : [val] "r" (val),
                : "r0", "r1", "cc"
            );
        }
    };

    pub fn get() Lock {
        const current_arch = builtin.cpu.arch;
        switch (current_arch) {
            .arm, .armeb, .thumb, .thumbeb => {},
            else => @compileError(std.fmt.comptimePrint("Unsupported architecture for built in lock support: {any}", .{builtin.cpu.arch})),
        }

        if (builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v6m)) or builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v8m))) {
            return .{
                .context = &ctx,
                .lockFn = ArmV6mV8m.lock,
                .unlockFn = ArmV6mV8m.unlock,
            };
        } else if (builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v7m)) or builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v7em)) or builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v8m_main))) {
            return .{
                .context = &ctx,
                .lockFn = ArmV7mV7emV8mMain.lock,
                .unlockFn = ArmV7mV7emV8mMain.unlock,
            };
        } else if (builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v7a)) or builtin.cpu.features.isEnabled(@intFromEnum(std.Target.arm.Feature.v7r))) {
            return .{
                .context = &ctx,
                .lockFn = ArmV7aV7r.lock,
                .unlockFn = ArmV7aV7r.unlock,
            };
        } else {
            @compileError(std.fmt.comptimePrint("Unsupported ARM CPU for built in lock support: {any}", .{builtin.cpu}));
        }
    }
};

/// Empty lock implementation that allows RTT to be used without lock protection
pub const empty = struct {
    fn lock(_: *const anyopaque) void {}
    fn unlock(_: *const anyopaque) void {}

    pub fn get() Lock {
        return .{ .context = @constCast(@ptrCast(&{})), .lockFn = lock, .unlockFn = unlock };
    }
};
