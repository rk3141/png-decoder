const std = @import("std");

const png = @import("./png.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const file = try std.fs.cwd().openFile("test.png", .{});

    const freader = file.reader();

    var buf_reader = std.io.bufferedReader(freader);

    var image = try png.Image.init(allocator, buf_reader.reader().any());
    defer image.deinit();

    try image.read();
    std.debug.print("{any}", .{image.raw_reconstruced_image});
}
