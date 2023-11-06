const uefi = @import("std").os.uefi;
const fmt = @import("std").fmt;

// EFI uses UCS-2 encoded null-terminated strings. UCS-2 encodes
// code points in exactly 16 bit. Unlike UTF-16, it does not support all
// Unicode code points.
// We need to print each character in an [_]u8 individually because EFI
// encodes strings as UCS-2.
pub fn print(msg: []const u8) void {
    const con_out = uefi.system_table.con_out.?;
    for (msg) |c| {
        const c_ = [2]u16{ c, 0 }; // work around https://github.com/ziglang/zig/issues/4372
        _ = con_out.outputString(@ptrCast(&c_));
    }
}

// For use with formatting strings
var printf_buf: [100]u8 = undefined;

pub fn printf(comptime format: []const u8, args: anytype) void {
    buf_printf(printf_buf[0..], format, args);
}

pub fn buf_printf(buf: []u8, comptime format: []const u8, args: anytype) void {
    print(fmt.bufPrint(buf, format, args) catch unreachable);
}
