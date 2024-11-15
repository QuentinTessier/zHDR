const std = @import("std");

pub const HDR = @This();

const HDRLogger = std.log.scoped(.HDR);

pub const HDRParserError = error{
    NotHDRFile,
    InvalidDataFormat,
} | std.mem.Allocator.Error | std.io.AnyReader.Error | std.fmt.ParseIntError;

pub const HDRImage = struct {
    width: u32,
    height: u32,
    pixels: [][3]f32,
};

fn isValidFile(reader: std.io.AnyReader) !bool {
    var bytes: [11]u8 = undefined;
    _ = try reader.read(&bytes);

    return std.mem.eql(u8, &bytes, "#?RADIANCE\n") or std.mem.startsWith(u8, &bytes, "#?RGBE\n");
}

fn getFormat(reader: std.io.AnyReader) !bool {
    var buffer: [256]u8 = undefined;
    while (true) {
        const line = try reader.readUntilDelimiter(&buffer, '\n');
        std.log.info("{s}", .{line});
        if (line.len == 0) break;

        if (std.mem.startsWith(u8, line, "FORMAT")) {
            return std.mem.endsWith(u8, line, "32-bit_rle_rgbe");
        }
    }
    return false;
}

const RGBE = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    e: u8,

    pub fn isRLE(self: RGBE, width: u32) bool {
        const b: u32 = @intCast(self.b);
        const e: u32 = @intCast(self.e);
        const len = b << 8 | e;

        return !(self.r != 0x02 or self.g != 0x02 or (self.b & 0x80) == 1) and width == len;
    }
};

fn parseImageResolution(reader: std.io.AnyReader) ![2]u32 {
    _ = try reader.readByte();
    var buffer: [64]u8 = undefined;
    const line = try reader.readUntilDelimiter(&buffer, '\n');

    if (!std.mem.startsWith(u8, line, "-Y ")) {
        HDRLogger.warn("Image flipping and rotation isn't yet supported, |{s}|", .{line});
        return error.InvalidDataFormat;
    }
    const end0 = std.mem.indexOf(u8, line[3..], " ") orelse return error.InvalidDataFormat;
    const Y = try std.fmt.parseInt(u32, line[3 .. 3 + end0], 10);

    if (!std.mem.startsWith(u8, line[end0 + 4 ..], "+X ")) {
        HDRLogger.warn("Image flipping and rotation isn't yet supported", .{});
        return error.InvalidDataFormat;
    }
    const X = try std.fmt.parseInt(u32, line[end0 + 7 ..], 10);
    return .{ X, Y };
}

fn parsePixelData(allocator: std.mem.Allocator, reader: std.io.AnyReader, width: u32, height: u32, imageData: [][3]f32) HDRParserError!void {
    var scanline = try allocator.alloc(u8, @intCast(width * 4));
    defer allocator.free(scanline);

    std.debug.print("{} {}\n", .{ width, height });
    var i: u32 = 0;

    for (0..@intCast(height)) |y| {
        const rleLineMarker = try reader.readStruct(RGBE);
        if (!rleLineMarker.isRLE(width)) return error.InvalidDataFormat;

        for (0..4) |k| {
            i = 0;
            var nleft: u32 = undefined;
            while (true) {
                nleft = width - i;
                if (nleft <= 0) break;
                const count = try reader.readByte();
                if (count > 128) {
                    const value = try reader.readByte();
                    const lCount = count - 128;
                    if (lCount > nleft) return error.InvalidDataFormat;
                    for (0..@intCast(lCount)) |_| {
                        scanline[i * 4 + k] = value;
                        i += 1;
                    }
                } else {
                    if (count > nleft) return error.InvalidDataFormat;
                    for (0..@intCast(count)) |_| {
                        scanline[i * 4 + k] = try reader.readByte();
                        i += 1;
                    }
                }
            }
        }

        for (0..@intCast(width)) |x| {
            const pixel: *[3]f32 = &imageData[y * @as(usize, @intCast(width)) + x];
            const s = std.mem.bytesAsValue(RGBE, scanline[x * 4 .. x * 4 + 3]);

            if (s.e != 0) {
                const E = std.math.ldexp(@as(f32, 1.0), @as(i32, @intCast(s.e)) - @as(i32, 128 + 8));
                pixel.*[0] = @as(f32, @floatFromInt(s.r)) * E;
                pixel.*[1] = @as(f32, @floatFromInt(s.g)) * E;
                pixel.*[2] = @as(f32, @floatFromInt(s.b)) * E;
            } else {
                pixel.* = .{ 0, 0, 0 };
            }
        }
    }
}

pub fn parse(allocator: std.mem.Allocator, reader: std.io.AnyReader) !HDRImage {
    if (!(try isValidFile(reader))) {
        return error.NotHDRFile;
    }

    if (!(try getFormat(reader))) {
        return error.InvalidDataFormat;
    }

    const res = try parseImageResolution(reader);
    const imageData: [][3]f32 = try allocator.alloc([3]f32, @intCast(res[0] * res[1]));
    errdefer {
        allocator.free(imageData);
    }

    try parsePixelData(allocator, reader, res[0], res[1], imageData);

    return .{
        .width = res[0],
        .height = res[1],
        .pixels = imageData,
    };
}

pub fn parseFromFile(allocator: std.mem.Allocator, file: std.fs.File) !HDRImage {
    return parse(allocator, file.reader().any());
}

pub fn parseFromFilePath(allocator: std.mem.Allocator, filepath: []const u8) !HDRImage {
    var file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    return parse(allocator, file.reader().any());
}

pub fn releaseImage(allocator: std.mem.Allocator, img: *HDRImage) void {
    allocator.free(img.pixels);
    img.width = 0;
    img.height = 0;
}
