const std = @import("std");
const uefi = std.os.uefi;
const proto = std.os.uefi.protocol;
const ArrayList = std.ArrayList;
const FilePathDevicePath = std.os.uefi.DevicePath.Media.FilePathDevicePath;
const EndEntireDevicePath = std.os.uefi.DevicePath.End.EndEntireDevicePath;

const console = @import("./console.zig");

const utf16str = std.unicode.utf8ToUtf16LeStringLiteral;

const Allocator = std.mem.Allocator;
var pool_alloc_state: std.heap.ArenaAllocator = undefined;
var pool_alloc: Allocator = undefined;

pub fn main() void {
    _ = efi_main() catch unreachable;
}

pub fn efi_main() !uefi.Status {
    pool_alloc_state = std.heap.ArenaAllocator.init(uefi.pool_allocator);
    pool_alloc = pool_alloc_state.allocator();

    try console.reset();
    try console.print("Welcome to the container bootloader.\r\n");

    const boot_services = uefi.system_table.boot_services.?;
    defer _ = boot_services.stall(10 * 1000 * 1000);

    var handles = blk: {
        var handle_ptr: [*]uefi.Handle = undefined;
        var res_size: usize = undefined;

        try boot_services.locateHandleBuffer(
            .ByProtocol,
            &proto.SimpleFileSystem.guid,
            null,
            &res_size,
            &handle_ptr,
        ).err();

        break :blk handle_ptr[0..res_size];
    };
    defer uefi.raw_pool_allocator.free(handles);

    var manifests = ArrayList(Manifest).init(pool_alloc);
    defer manifests.deinit();

    for (handles) |handle| {
        var fs = try boot_services.openProtocolSt(proto.SimpleFileSystem, handle);
        var fp: *const proto.File = undefined;
        try fs.openVolume(&fp).err();

        var conf_name = try std.mem.concat(
            pool_alloc,
            u16,
            &[_][]const u16{
                utf16str("ociboot\\manifest.json"),
                &[_]u16{0},
            },
        );
        defer pool_alloc.free(conf_name);

        var conf_sentinel = conf_name[0 .. conf_name.len - 1 :0];

        var efp: *proto.File = undefined;
        fp.open(&efp, conf_sentinel, proto.File.efi_file_mode_read, 0).err() catch |e| {
            try console.print("ERROR");
            return e;
        };

        // const json = try efp.reader().readAllAlloc(pool_alloc, 1024 * 1024);
        // defer pool_alloc.free(json);

        // const parsed = try std.json.parseFromSlice(
        //     []Manifest,
        //     pool_alloc,
        //     json,
        //     .{ .ignore_unknown_fields = true },
        // );
        // defer parsed.deinit();

        // for (parsed.value) |manifest| {
        //     try console.printf("Appending manifest {s}\n", .{manifest.RepoTags});
        //     try manifests.append(manifest);
        // }
        //
        //
        var file_name = try std.mem.concat(
            pool_alloc,
            u16,
            &[_][]const u16{
                utf16str("ociboot\\boot\\vmlinuz"),
                &[_]u16{0},
            },
        );
        defer pool_alloc.free(file_name);

        var args = try std.mem.concat(
            pool_alloc,
            u16,
            &[_][]const u16{
                utf16str("root=/dev/ram0"),
                utf16str(" init=/bin/bash"),
                &[_]u16{0},
            },
        );
        defer pool_alloc.free(args);

        var file_sentinel = file_name[0 .. file_name.len - 1 :0];
        var args_sentinel = args[0 .. args.len - 1 :0];

        boot(handle, file_sentinel, args_sentinel) catch |err| {
            try console.printf("ERROR LOADING: {}", .{err});
        };
    }

    try console.printf("Found {} manifests\n", .{manifests.items.len});

    return uefi.Status.Success;
}

const Manifest = struct { Config: []u8, RepoTags: [][]u8, Layers: [][]u8 };

fn boot(handle: uefi.Handle, file_name: [:0]const u16, options: [:0]u16) !void {
    const boot_services = uefi.system_table.boot_services.?;

    var device = try boot_services.openProtocolSt(proto.DevicePath, handle);

    try console.printf("Found device", .{});

    var img: ?uefi.Handle = undefined;

    var image_path = try file_path(pool_alloc, device, file_name);

    try console.printf("Found image_path", .{});

    try boot_services.loadImage(false, uefi.handle, image_path, null, 0, &img).err();

    try console.printf("Loaded image", .{});

    var img_proto = try boot_services.openProtocolSt(proto.LoadedImage, img.?);

    img_proto.load_options = options.ptr;
    img_proto.load_options_size = @as(u32, @intCast((options.len + 1) * @sizeOf(u16)));

    try console.printf("Starting image...", .{});

    try boot_services.startImage(img.?, null, null).err();
}

fn file_path(
    alloc: std.mem.Allocator,
    dpp: *proto.DevicePath,
    path: [:0]const u16,
) !*proto.DevicePath {
    var size = dpp_size(dpp);

    // u16 of path + null terminator -> 2 * (path.len + 1)
    var buf = try alloc.alloc(u8, size + 2 * (path.len + 1) + @sizeOf(proto.DevicePath));

    std.mem.copy(u8, buf, @as([*]u8, @ptrCast(dpp))[0..size]);

    // Pointer to the start of the protocol, which is - 4 as the size includes the node length field.
    var new_dpp = @as(*FilePathDevicePath, @ptrCast(buf.ptr + size - 4));

    new_dpp.type = .Media;
    new_dpp.subtype = .FilePath;
    new_dpp.length = @sizeOf(FilePathDevicePath) + 2 * (@as(u16, @intCast(path.len)) + 1);

    var ptr: [*:0]u16 = @alignCast(@ptrCast(@as([*]u8, @ptrCast(new_dpp)) + @sizeOf(FilePathDevicePath)));

    for (path, 0..) |s, i|
        ptr[i] = s;

    ptr[path.len] = 0;

    var next = @as(*EndEntireDevicePath, @ptrCast(@as([*]u8, @ptrCast(new_dpp)) + new_dpp.length));
    next.type = .End;
    next.subtype = .EndEntire;
    next.length = @sizeOf(EndEntireDevicePath);

    return @as(*proto.DevicePath, @ptrCast(buf.ptr));
}

fn dpp_size(dpp: *proto.DevicePath) usize {
    var start = dpp;

    var node = dpp;
    while (node.type != .End) {
        node = @ptrFromInt(@intFromPtr(node) + node.length);
    }

    return (@intFromPtr(node) + node.length) - @intFromPtr(start);
}
