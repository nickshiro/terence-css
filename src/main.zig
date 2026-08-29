const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const terence_css = @import("terence_css");

const Mode = enum { stdout, write, check };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var mode: Mode = .stdout;
    var first_path: usize = 1;
    while (first_path < args.len) : (first_path += 1) {
        const arg = args[first_path];
        if (std.mem.eql(u8, arg, "--")) {
            first_path += 1;
            break;
        }

        if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--write")) {
            if (mode == .check) return usage(init.io);
            mode = .write;
            continue;
        }

        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--check")) {
            if (mode == .write) return usage(init.io);
            mode = .check;
            continue;
        }

        if (std.mem.eql(u8, arg, "-") or !std.mem.startsWith(u8, arg, "-")) {
            break;
        }

        return usage(init.io);
    }

    const paths = args[first_path..];

    if (mode == .write) {
        if (paths.len == 0) {
            return usage(init.io);
        }

        for (paths) |path| {
            if (std.mem.eql(u8, path, "-")) {
                return usage(init.io);
            }

            formatFile(init.io, init.gpa, path) catch |err| {
                try reportError(init.io, path, err);
                return 1;
            };
        }

        return 0;
    }

    if (mode == .check) {
        if (paths.len == 0) return usage(init.io);

        var stdout_buf: [4096]u8 = undefined;
        var stdout = Io.File.stdout().writer(init.io, &stdout_buf);
        var clean = true;
        for (paths) |path| {
            if (std.mem.eql(u8, path, "-")) return usage(init.io);
            const formatted = fileIsFormatted(init.io, init.gpa, path) catch |err| {
                try reportError(init.io, path, err);
                return 1;
            };
            if (!formatted) {
                try stdout.interface.print("{s}\n", .{path});
                clean = false;
            }
        }
        try stdout.interface.flush();
        return if (clean) 0 else 1;
    }

    if (paths.len > 1) {
        return usage(init.io);
    }

    const source = if (paths.len == 1 and !std.mem.eql(u8, paths[0], "-"))
        try Io.Dir.cwd().readFileAlloc(init.io, paths[0], init.gpa, .unlimited)
    else source: {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_r = Io.File.stdin().reader(init.io, &stdin_buf);
        break :source try stdin_r.interface.allocRemaining(init.gpa, .unlimited);
    };
    defer init.gpa.free(source);

    const formatted = try terence_css.formatStylesheetAlloc(init.gpa, source, .{});
    defer init.gpa.free(formatted);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout_w.interface.writeAll(formatted);
    try stdout_w.interface.flush();

    return 0;
}

fn formatFile(io: Io, allocator: Allocator, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const stat = try cwd.statFile(io, path, .{ .follow_symlinks = false });
    if (stat.kind == .sym_link) {
        return error.SymbolicLink;
    }

    const source = try cwd.readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(source);
    const formatted = try terence_css.formatStylesheetAlloc(allocator, source, .{
        .error_mode = .strict,
    });
    defer allocator.free(formatted);

    if (std.mem.eql(u8, source, formatted)) {
        return;
    }

    var atomic = try cwd.createFileAtomic(io, path, .{
        .permissions = stat.permissions,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.setPermissions(io, stat.permissions);

    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(formatted);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn fileIsFormatted(io: Io, allocator: Allocator, path: []const u8) !bool {
    const source = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(source);
    const formatted = try terence_css.formatStylesheetAlloc(allocator, source, .{
        .error_mode = .strict,
    });
    defer allocator.free(formatted);

    return std.mem.eql(u8, source, formatted);
}

fn usage(io: Io) !u8 {
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(
        "usage: terence-css [-w|--write | -c|--check] [FILE...]\n",
    );
    try stderr.interface.flush();

    return 2;
}

fn reportError(io: Io, path: []const u8, err: anyerror) !void {
    var buffer: [4096]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buffer);
    try stderr.interface.print("terence-css: {s}: {s}\n", .{ path, @errorName(err) });
    try stderr.interface.flush();
}
