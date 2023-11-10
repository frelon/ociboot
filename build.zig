const std = @import("std");
const Builder = @import("std").build.Builder;
const Target = @import("std").Target;
const CrossTarget = @import("std").zig.CrossTarget;
const builtin = @import("builtin");

const allocator = std.heap.page_allocator;

pub fn build(b: *Builder) !void {
    const x64_exe = b.addExecutable(.{ .name = "bootx64", .root_source_file = .{ .path = "src/main.zig" }, .target = CrossTarget{
        .cpu_arch = Target.Cpu.Arch.x86_64,
        .os_tag = Target.Os.Tag.uefi,
        .abi = Target.Abi.msvc,
    } });
    const x64_artifact = b.addInstallArtifact(x64_exe, .{});
    x64_artifact.dest_sub_path = "efi/boot/bootx64.efi";
    b.default_step.dependOn(&x64_artifact.step);

    const aa64_exe = b.addExecutable(.{ .name = "bootaa64", .root_source_file = .{ .path = "src/main.zig" }, .target = CrossTarget{
        .cpu_arch = Target.Cpu.Arch.aarch64,
        .os_tag = Target.Os.Tag.uefi,
        .abi = Target.Abi.msvc,
    } });
    const aa64_artifact = b.addInstallArtifact(aa64_exe, .{});
    aa64_artifact.dest_sub_path = "efi/boot/bootaa64.efi";
    b.default_step.dependOn(&aa64_artifact.step);

    const docker_build_leap_cmd = b.addSystemCommand(&[_][]const u8{ "docker", "build", "--quiet", "--load", "-t", "leap:15.5", "-f", "Dockerfile", "./" });

    const docker_save_cmd = b.addSystemCommand(&[_][]const u8{ "docker", "save", "leap:15.5", "-o" });
    const images_file = docker_save_cmd.addOutputFileArg("images.tar");
    docker_save_cmd.step.dependOn(&docker_build_leap_cmd.step);

    const install_images = b.addInstallFile(images_file, "bin/ociboot/images.tar");
    install_images.step.dependOn(&docker_save_cmd.step);

    const dir = install_images.dest_builder.getInstallPath(install_images.dir, "bin/ociboot");
    const file = install_images.dest_builder.getInstallPath(install_images.dir, install_images.dest_rel_path);
    const extract_images_cmd = b.addSystemCommand(&[_][]const u8{ "tar", "xf", file, "-C", dir });
    extract_images_cmd.step.dependOn(&install_images.step);

    const target = b.standardTargetOptions(.{});
    const qemu_prg = if (target.cpu_arch == Target.Cpu.Arch.aarch64) "qemu-system-aarch64" else "qemu-system-x86_64";
    const firmware = if (target.cpu_arch == Target.Cpu.Arch.aarch64) "/usr/share/qemu/aavmf-aarch64-ms-code.bin" else "/usr/share/qemu/ovmf-x86_64-ms.bin";
    const machine = if (target.cpu_arch == Target.Cpu.Arch.aarch64) "virt" else "pc";

    const qemu_cmd = b.addSystemCommand(&[_][]const u8{ qemu_prg, "-nographic", "-machine", machine, "-bios", firmware, "-m", "2G", "-nographic", "-drive", "format=raw,file=fat:rw:./zig-out/bin" });

    qemu_cmd.step.dependOn(&x64_artifact.step);
    qemu_cmd.step.dependOn(&aa64_artifact.step);
    qemu_cmd.step.dependOn(&extract_images_cmd.step);

    const run_step = b.step("run", "Runs a QEMU virtual machine with the built bootloader");
    run_step.dependOn(&qemu_cmd.step);

    // Tests
    const optimize = b.standardOptimizeOption(.{});
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
