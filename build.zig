const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gstep = b.getInstallStep();

    const avl = b.createModule(.{
        .root_source_file = b.path("src/avl_set.zig"),
        .target = target,
        .optimize = optimize,
    });

    const types = b.createModule(.{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "avl", .module = avl },
        },
    });

    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types },
        },
    });

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server_mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types },
            .{ .name = "utils", .module = utils },
        },
    });

    const server = b.addExecutable(.{
        .name = "server",
        .use_lld = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server", .module = server_mod },
                .{ .name = "avl", .module = avl },
                .{ .name = "utils", .module = utils },
                .{ .name = "types", .module = types },
            },
        }),
    });
    const install_server = b.addInstallArtifact(server, .{});
    gstep.dependOn(&install_server.step);
    const build_server = b.step("server", "Builds the server binary");
    build_server.dependOn(&install_server.step);
    const run_server = b.step("run-server", "Run the server");
    const server_cmd = b.addRunArtifact(server);
    run_server.dependOn(&server_cmd.step);
    server_cmd.step.dependOn(&install_server.step);
    if (b.args) |args| server_cmd.addArgs(args);

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client_mod.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "types", .module = types },
            .{ .name = "utils", .module = utils },
        },
    });

    const client = b.addExecutable(.{
        .name = "client",
        .use_lld = false,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "client", .module = client_mod },
                .{ .name = "avl", .module = avl },
                .{ .name = "utils", .module = utils },
                .{ .name = "types", .module = types },
            },
        }),
    });
    const install_client = b.addInstallArtifact(client, .{});
    gstep.dependOn(&install_client.step);
    const build_client = b.step("client", "Builds the client binary");
    build_client.dependOn(&install_client.step);
    const run_client = b.step("run-client", "Run the client");
    const client_cmd = b.addRunArtifact(client);
    run_client.dependOn(&client_cmd.step);
    client_cmd.step.dependOn(&install_client.step);
    if (b.args) |args| client_cmd.addArgs(args);
}
