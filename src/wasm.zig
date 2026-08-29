//! Stable WebAssembly boundary for the JavaScript package.
//!
//! The ABI exposes only 32-bit integers. JavaScript owns input allocations;
//! result handles own their formatted byte slices until `terence_result_free`.

const std = @import("std");
const terence_css = @import("terence_css");

const allocator = std.heap.wasm_allocator;

const abi_version: u32 = 1;
const final_newline_flag: u32 = 1 << 0;
const strict_flag: u32 = 1 << 1;
const known_flags = final_newline_flag | strict_flag;

const ErrorCode = enum(u32) {
    ok = 0,
    out_of_memory = 1,
    invalid_css = 2,
    format_failed = 3,
    invalid_argument = 4,
};

const Result = struct {
    bytes: []u8,
    error_code: ErrorCode,
};

export fn terence_abi_version() u32 {
    return abi_version;
}

export fn terence_alloc(len: u32) u32 {
    if (len == 0) {
        return 0;
    }

    const bytes = allocator.alloc(u8, len) catch return 0;

    return pointerToU32(bytes.ptr);
}

export fn terence_free(ptr: u32, len: u32) void {
    if (len == 0) {
        return;
    }

    if (ptr == 0) {
        return;
    }

    allocator.free(bytesFromRaw(ptr, len));
}

export fn terence_format(
    input_ptr: u32,
    input_len: u32,
    indent_width: u32,
    flags: u32,
) u32 {
    if (flags & ~known_flags != 0 or (input_len != 0 and input_ptr == 0)) {
        return createResult(&.{}, .invalid_argument);
    }

    const input: []const u8 = if (input_len == 0)
        ""
    else
        bytesFromRaw(input_ptr, input_len);
    const formatted = terence_css.formatStylesheetAlloc(allocator, input, .{
        .indent_width = indent_width,
        .final_newline = flags & final_newline_flag != 0,
        .error_mode = if (flags & strict_flag != 0) .strict else .recover,
    }) catch |err| {
        return createResult(&.{}, switch (err) {
            error.OutOfMemory, error.WriteFailed => .out_of_memory,
            error.InvalidCss => .invalid_css,
            else => .format_failed,
        });
    };

    return createResult(formatted, .ok);
}

export fn terence_result_ptr(handle: u32) u32 {
    if (handle == 0) {
        return 0;
    }

    const result = resultFromHandle(handle);

    if (result.bytes.len == 0) {
        return 0;
    }

    return pointerToU32(result.bytes.ptr);
}

export fn terence_result_len(handle: u32) u32 {
    if (handle == 0) {
        return 0;
    }

    return @intCast(resultFromHandle(handle).bytes.len);
}

export fn terence_result_error(handle: u32) u32 {
    if (handle == 0) {
        return @intFromEnum(ErrorCode.out_of_memory);
    }

    return @intFromEnum(resultFromHandle(handle).error_code);
}

export fn terence_result_free(handle: u32) void {
    if (handle == 0) {
        return;
    }

    const result = resultFromHandle(handle);

    if (result.bytes.len != 0) {
        allocator.free(result.bytes);
    }

    allocator.destroy(result);
}

fn createResult(bytes: []u8, error_code: ErrorCode) u32 {
    const result = allocator.create(Result) catch {
        if (bytes.len != 0) {
            allocator.free(bytes);
        }

        return 0;
    };

    result.* = .{ .bytes = bytes, .error_code = error_code };

    return pointerToU32(result);
}

fn resultFromHandle(handle: u32) *Result {
    return @ptrFromInt(@as(usize, handle));
}

fn bytesFromRaw(ptr: u32, len: u32) []u8 {
    const many: [*]u8 = @ptrFromInt(@as(usize, ptr));
    return many[0..len];
}

fn pointerToU32(ptr: anytype) u32 {
    return @intCast(@intFromPtr(ptr));
}
