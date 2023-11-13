const std = @import("std");
const tar = @import("./tar.zig");

const uefi = std.os.uefi;
const proto = std.os.uefi.protocol;
const ArrayList = std.ArrayList;
const FilePathDevicePath = std.os.uefi.DevicePath.Media.FilePathDevicePath;
const EndEntireDevicePath = std.os.uefi.DevicePath.End.EndEntireDevicePath;

const console = @import("./console.zig");

const utf16str = std.unicode.utf8ToUtf16LeStringLiteral;
const utf16le = std.unicode.utf8ToUtf16LeWithNull;

const Allocator = std.mem.Allocator;

const Manifest = struct { Config: []u8, RepoTags: [][]u8, Layers: [][]u8 };

pub fn main() void {
    _ = efi_main() catch unreachable;
}

pub fn efi_main() !uefi.Status {
    var pool_alloc_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(uefi.pool_allocator);
    var pool_alloc = pool_alloc_state.allocator();

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

        var conf_name = try std.mem.concatWithSentinel(pool_alloc, u16, &[_][]const u16{
            utf16str("ociboot\\manifest.json"),
            &[_]u16{0},
        }, 0);
        defer pool_alloc.free(conf_name);

        var efp: *proto.File = undefined;
        fp.open(&efp, conf_name, proto.File.efi_file_mode_read, 0).err() catch |e| {
            try console.print("Error opening manifest.json");
            return e;
        };

        const json = try efp.reader().readAllAlloc(pool_alloc, 1024 * 1024);
        defer pool_alloc.free(json);

        const parsed = try std.json.parseFromSlice(
            []Manifest,
            pool_alloc,
            json,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        for (parsed.value) |manifest| {
            try console.printf("Appending manifest {s}\n", .{manifest.RepoTags});
            try manifests.append(manifest);

            // try the boot!
            const layer = manifest.Layers[0];
            _ = std.mem.replace(u8, layer, "/", "\\", layer);

            const utf16layer = try utf16le(pool_alloc, layer);
            try console.printf("Opening layer {s}\n", .{layer});

            var tar_name = try std.mem.concatWithSentinel(pool_alloc, u16, &[_][]const u16{
                utf16str("ociboot\\"),
                utf16layer,
                &[_]u16{0},
            }, 0);
            defer pool_alloc.free(tar_name);

            var tar_fp: *proto.File = undefined;
            fp.open(&tar_fp, tar_name, proto.File.efi_file_mode_read, 0).err() catch |e| {
                try console.print("Error opening layer");
                return e;
            };

            const fileinfo = try tar.stat(tar_fp.reader(), "boot/vmlinuz");
            try console.printf("Found kernel: {s}\n", .{fileinfo.?.filename()});

            try tar_fp.setPosition(0).err();

            var kernel: [*]align(8) u8 = undefined;
            const const_size = 100 * 1000 * 1000;
            try uefi.system_table.boot_services.?.allocatePool(uefi.efi_pool_memory_type, const_size, &kernel).err();
            defer uefi.system_table.boot_services.?.freePool(kernel).err() catch {};
            const size = try tar.readFile(tar_fp.reader(), fileinfo.?.filename(), kernel);

            try console.printf("Kernel size {}\n", .{size});

            var args = try std.mem.concat(
                pool_alloc,
                u16,
                &[_][]const u16{
                    utf16str("root=testitest console=ttyS0"),
                    &[_]u16{0},
                },
            );
            defer pool_alloc.free(args);

            var img: ?uefi.Handle = undefined;
            try boot_services.loadImage(false, uefi.handle, null, kernel, const_size, &img).err();

            try console.printf("Loaded image\n", .{});

            var img_proto = try boot_services.openProtocolSt(proto.LoadedImage, img.?);

            img_proto.load_options = args.ptr;
            img_proto.load_options_size = @as(u32, @intCast((args.len + 1) * @sizeOf(u16)));

            try console.printf("Starting image...\n", .{});

            try boot_services.startImage(img.?, null, null).err();
        }
    }

    try console.printf("Found {} manifests\n", .{manifests.items.len});

    return uefi.Status.Success;
}
