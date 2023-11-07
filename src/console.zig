const uefi = @import("std").os.uefi;
const fmt = @import("std").fmt;
const unicode = @import("std").unicode;

// EFI uses UCS-2 encoded null-terminated strings. UCS-2 encodes
// code points in exactly 16 bit. Unlike UTF-16, it does not support all
// Unicode code points.
// We need to print each character in an [_]u8 individually because EFI
// encodes strings as UCS-2.
pub fn print(comptime msg: []const u8) !void {
    const con_out = uefi.system_table.con_out.?;
    const status = con_out.outputString(unicode.utf8ToUtf16LeStringLiteral(msg));
    return status.err();
}

pub fn print16(msg: [*:0]const u16) !void {
    const con_out = uefi.system_table.con_out.?;
    return con_out.outputString(msg).err();
}

pub fn printf(comptime format: []const u8, args: anytype) !void {
    const con_out = uefi.system_table.con_out.?;

    var utf16: [2048:0]u16 = undefined;
    var format_buf: [2048]u8 = undefined;

    var slice = try fmt.bufPrint(&format_buf, format, args);
    var length = try unicode.utf8ToUtf16Le(&utf16, slice);

    utf16[length] = 0;

    return con_out.outputString(&utf16).err();
}
