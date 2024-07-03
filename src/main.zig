const std = @import("std");

const png = @import("./png.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var image = try png.Image.from_file(allocator, "test.png");
    defer image.deinit();

    try image.read();
    std.debug.print("{any}\n", .{image.raw_reconstruced_image});
    std.debug.print("w: {}, h: {}\n", .{ image.width, image.height });
}
