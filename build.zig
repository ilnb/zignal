const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "client", .module = server_mod },
                .{ .name = "avl", .module = avl },
                .{ .name = "utils", .module = utils },
                .{ .name = "types", .module = types },
            },
        }),
    });

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
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server", .module = client_mod },
                .{ .name = "avl", .module = avl },
                .{ .name = "utils", .module = utils },
                .{ .name = "types", .module = types },
            },
        }),
    });

    b.installArtifact(server);

    const server_step = b.step("run_server", "Run the server");
    const server_cmd = b.addRunArtifact(server);
    server_step.dependOn(&server_cmd.step);
    server_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| server_cmd.addArgs(args);

    b.installArtifact(client);

    const client_step = b.step("run_client", "Run the client");
    const client_cmd = b.addRunArtifact(client);
    client_step.dependOn(&client_cmd.step);
    client_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| client_cmd.addArgs(args);
}
