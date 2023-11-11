const std = @import("std");
const console = @import("./console.zig");
const assert = std.debug.assert;

pub const Header = struct {
    bytes: *const [512]u8,

    pub const FileType = enum(u8) {
        normal_alias = 0,
        normal = '0',
        hard_link = '1',
        symbolic_link = '2',
        character_special = '3',
        block_special = '4',
        directory = '5',
        fifo = '6',
        contiguous = '7',
        global_extended_header = 'g',
        extended_header = 'x',
        _,
    };

    pub fn fileSize(header: Header) !u64 {
        const raw = header.bytes[124..][0..12];
        const ltrimmed = std.mem.trimLeft(u8, raw, "0");
        const rtrimmed = std.mem.trimRight(u8, ltrimmed, " \x00");
        if (rtrimmed.len == 0) return 0;
        return std.fmt.parseInt(u64, rtrimmed, 8);
    }

    pub fn is_ustar(header: Header) bool {
        return std.mem.eql(u8, header.bytes[257..][0..6], "ustar\x00");
    }

    /// Includes prefix concatenated, if any.
    /// Return value may point into Header buffer, or might point into the
    /// argument buffer.
    /// TODO: check against "../" and other nefarious things
    pub fn fullFileName(header: Header, buffer: *[64]u8) ![]const u8 {
        const n = name(header);
        if (!is_ustar(header))
            return n;
        const p = prefix(header);
        if (p.len == 0)
            return n;
        @memcpy(buffer[0..p.len], p);
        buffer[p.len] = '/';
        @memcpy(buffer[p.len + 1 ..][0..n.len], n);
        return buffer[0 .. p.len + 1 + n.len];
    }

    pub fn name(header: Header) []const u8 {
        return str(header, 0, 0 + 100);
    }

    pub fn linkName(header: Header) []const u8 {
        return str(header, 157, 157 + 100);
    }

    pub fn prefix(header: Header) []const u8 {
        return str(header, 345, 345 + 155);
    }

    pub fn fileType(header: Header) FileType {
        const result: FileType = @enumFromInt(header.bytes[156]);
        if (result == .normal_alias) return .normal;
        return result;
    }

    fn str(header: Header, start: usize, end: usize) []const u8 {
        var i: usize = start;
        while (i < end) : (i += 1) {
            if (header.bytes[i] == 0) break;
        }
        return header.bytes[start..i];
    }
};

const Buffer = struct {
    buffer: [512 * 8]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    pub fn readChunk(b: *Buffer, reader: anytype, count: usize) ![]const u8 {
        b.ensureCapacity(1024);

        const ask = @min(b.buffer.len - b.end, count -| (b.end - b.start));
        b.end += try reader.readAtLeast(b.buffer[b.end..], ask);

        return b.buffer[b.start..b.end];
    }

    pub fn advance(b: *Buffer, count: usize) void {
        b.start += count;
        assert(b.start <= b.end);
    }

    pub fn skip(b: *Buffer, reader: anytype, count: usize) !void {
        if (b.start + count > b.end) {
            try reader.skipBytes(b.start + count - b.end, .{});
            b.start = b.end;
        } else {
            b.advance(count);
        }
    }

    inline fn ensureCapacity(b: *Buffer, count: usize) void {
        if (b.buffer.len - b.start < count) {
            const dest_end = b.end - b.start;
            @memcpy(b.buffer[0..dest_end], b.buffer[b.start..b.end]);
            b.end = dest_end;
            b.start = 0;
        }
    }
};

const FileInfo = struct {
    fileName: []u8,
    size: u64,
};

pub fn stat(reader: anytype, fileName: []const u8, comptime maxPathBytes: u8) !FileInfo {
    var file_name_buffer: [maxPathBytes]u8 = undefined;
    var file_name_override_len: usize = 0;
    var buffer: Buffer = .{};
    header: while (true) {
        const chunk = try buffer.readChunk(reader, 1024);
        switch (chunk.len) {
            0 => return FileInfo{ .fileName = "", .size = 0 },
            1...511 => return error.UnexpectedEndOfStream,
            else => {},
        }
        buffer.advance(512);

        const header: Header = .{ .bytes = chunk[0..512] };
        const file_size = try header.fileSize();
        const rounded_file_size = std.mem.alignForward(u64, file_size, 512);
        const pad_len: usize = @intCast(rounded_file_size - file_size);
        const unstripped_file_name = if (file_name_override_len > 0)
            file_name_buffer[0..file_name_override_len]
        else
            try header.fullFileName(&file_name_buffer);
        file_name_override_len = 0;
        switch (header.fileType()) {
            .directory => {
                buffer.skip(reader, @intCast(rounded_file_size)) catch return error.TarHeadersTooBig;
                continue :header;
            },
            .normal => {
                if (file_size == 0 and unstripped_file_name.len == 0) return FileInfo{ .fileName = "", .size = 0 };

                if (std.mem.eql(u8, fileName, unstripped_file_name)) {
                    try console.printf("FOUND {s}", .{fileName});
                    return FileInfo{
                        .fileName = undefined,
                        .size = file_size,
                    };
                }

                var file_off: usize = 0;
                while (true) {
                    const temp = try buffer.readChunk(reader, @intCast(rounded_file_size + 512 - file_off));
                    if (temp.len == 0) return error.UnexpectedEndOfStream;
                    const slice = temp[0..@intCast(@min(file_size - file_off, temp.len))];
                    // if (file) |f| try f.writeAll(slice);

                    file_off += slice.len;
                    buffer.advance(slice.len);
                    if (file_off >= file_size) {
                        buffer.advance(pad_len);
                        continue :header;
                    }
                }
            },
            .symbolic_link => {
                if (std.mem.eql(u8, fileName, unstripped_file_name)) {
                    try console.printf("FOUND symlink {s} to {s}", .{ fileName, header.linkName() });
                    const link = header.linkName();
                    var ret = FileInfo{
                        .fileName = undefined, // std.mem.zeroes([maxPathBytes]u8);
                        .size = file_size,
                    };
                    @memcpy(ret.fileName, link);
                    return ret;
                }
            },
            else => |file_type| {
                _ = file_type;
            },
        }
    }

    return FileInfo{};
}

pub fn readFile(reader: anytype, fileName: []const u8, comptime maxPathBytes: u8, output: [*]u8) !usize {
    _ = output;
    var file_name_buffer: [maxPathBytes]u8 = undefined;
    var file_name_override_len: usize = 0;
    var buffer: Buffer = .{};
    header: while (true) {
        const chunk = try buffer.readChunk(reader, 1024);
        switch (chunk.len) {
            0 => return 0,
            1...511 => return error.UnexpectedEndOfStream,
            else => {},
        }
        buffer.advance(512);

        const header: Header = .{ .bytes = chunk[0..512] };
        const file_size = try header.fileSize();
        const rounded_file_size = std.mem.alignForward(u64, file_size, 512);
        const pad_len: usize = @intCast(rounded_file_size - file_size);
        const unstripped_file_name = if (file_name_override_len > 0)
            file_name_buffer[0..file_name_override_len]
        else
            try header.fullFileName(&file_name_buffer);
        file_name_override_len = 0;
        switch (header.fileType()) {
            .directory => {
                buffer.skip(reader, @intCast(rounded_file_size)) catch return error.TarHeadersTooBig;
                continue :header;
            },
            .normal => {
                if (file_size == 0 and unstripped_file_name.len == 0) return 0;

                if (std.mem.eql(u8, fileName, unstripped_file_name)) {
                    try console.printf("FOUND {s}", .{fileName});
                }

                var file_off: usize = 0;
                while (true) {
                    const temp = try buffer.readChunk(reader, @intCast(rounded_file_size + 512 - file_off));
                    if (temp.len == 0) return error.UnexpectedEndOfStream;
                    const slice = temp[0..@intCast(@min(file_size - file_off, temp.len))];
                    // if (file) |f| try f.writeAll(slice);

                    file_off += slice.len;
                    buffer.advance(slice.len);
                    if (file_off >= file_size) {
                        buffer.advance(pad_len);
                        continue :header;
                    }
                }
            },
            else => |file_type| {
                _ = file_type;
            },
        }
    }
}
