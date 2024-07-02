const std = @import("std");

const PNG_SIGN = "\x89PNG\r\n\x1a\n"; // if the file starts with these bytes its a png

const PNG_Chunk = struct {
    length: u32,
    chunk_type: [4]u8,
    chunk_data: []u8,

    fn is_img_header(self: PNG_Chunk) bool {
        return std.mem.eql(u8, &self.chunk_type, "IHDR");
    }
    fn is_img_data(self: PNG_Chunk) bool {
        return std.mem.eql(u8, &self.chunk_type, "IDAT");
    }
    fn is_img_end(self: PNG_Chunk) bool {
        return std.mem.eql(u8, &self.chunk_type, "IEND");
    }
};

const Image = packed struct {
    width: u32 = 0,
    height: u32 = 0,
    bitdepth: u8 = 0,
    color_type: u8 = 0,
    compression_method: u8 = 0,
    filter_method: u8 = 0,
    interlace_method: u8 = 0,
};

const PNG_Errors = error{ NotAPNG, WrongBitdepth, UnkownCompressionMethod, UnknownFilterMethod, UnknownInterlaceMethod };

pub fn main() (PNG_Errors || anyerror)!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const file = try std.fs.cwd().openFile("test.png", .{});

    var self = Image{};

    const freader = file.reader();

    var buf_reader = std.io.bufferedReader(freader);

    // var buf = std.mem.zeroes([8192]u8);
    // var n = try buf_reader.read(&buf);

    // var first_chunk = true;

    // var position_bklog: usize = 0;

    var png_sign: [8]u8 = undefined;
    _ = try buf_reader.read(&png_sign);
    if (!std.mem.eql(u8, PNG_SIGN, &png_sign)) {
        return error.NotAPNG;
    }

    var reading_data = false;
    var idat = std.ArrayList(u8).init(allocator);
    defer idat.deinit();

    while (true) {
        var len_chunk: [4]u8 = undefined;
        _ = try buf_reader.read(&len_chunk);
        const len = std.mem.readInt(u32, &len_chunk, .big); // length of the data

        var chunk_type: [4]u8 = undefined;
        _ = try buf_reader.read(&chunk_type);

        const chunk_data = try allocator.alloc(u8, len);
        defer allocator.free(chunk_data);
        _ = try buf_reader.read(chunk_data);

        var _crc: [4]u8 = undefined;
        _ = try buf_reader.read(&_crc);

        const crictical = chunk_type[0] >> 5 & 1 == 0;
        const public = chunk_type[1] >> 5 & 1 == 0;
        _ = chunk_type[2] >> 5 & 1 == 0; // is standard png chunk type bit
        _ = chunk_type[3] >> 5 & 1 == 0; // ignore the safe to copy bit cuz we dont need it ig?

        const chunk = PNG_Chunk{
            .length = len,
            .chunk_data = chunk_data,
            .chunk_type = chunk_type,
        };

        std.debug.print("len of {s} chunk: {d}, critical: {}, public: {}\n", .{ chunk.chunk_type, chunk.length, crictical, public });

        if (chunk.is_img_data()) {
            reading_data = true;
        } else if (chunk.is_img_header()) {
            // seperately reading width/height cuz for some reason they are not big endian
            const width: [4]u8 = chunk_data[0..4].*;
            const height: [4]u8 = chunk_data[4..8].*;
            self.width = std.mem.readInt(u32, &width, .big); // width of the image
            self.height = std.mem.readInt(u32, &height, .big); // height of the image
            self.bitdepth = chunk_data[8];
            // TODO: PLTE Chunk required for color type = 3; does not check currently
            self.color_type = chunk_data[9];
            self.compression_method = chunk_data[10];
            self.filter_method = chunk_data[11];
            self.interlace_method = chunk_data[12];
        } else if (chunk.is_img_end()) {
            reading_data = false;
            std.debug.print("{any}\n", .{self});
            std.debug.print("{any}\n", .{idat.items});

            var deflated_idat = std.ArrayList(u8).init(allocator);
            defer deflated_idat.deinit();

            var idat_stream = std.io.fixedBufferStream(idat.items[0..]);
            const idat_reader = idat_stream.reader();

            try std.compress.zlib.decompress(idat_reader, deflated_idat.writer());

            std.debug.print("{any}\n", .{deflated_idat.items});
            std.debug.print("{}\n", .{deflated_idat.items.len});

            break;
        }

        if (reading_data) {
            try idat.appendSlice(chunk_data);
        }
    }

    // while (n != 0) : (n = try buf_reader.read(&buf)) {
    //     var position: usize = position_bklog;

    //     if (first_chunk) {
    //         if (std.mem.eql(u8, buf[0..8], &PNG_SIGN)) {
    //             std.debug.print("its a png\n", .{});
    //             position += 8;
    //         } else {
    //             break;
    //         }
    //     }
    //     if (self.filter_method != 0) {
    //         return error.UnknownFilterMethod;
    //     }
    //     while (position < 4096) {
    //         defer position += 4; // skip the CRC chunk

    //         const len_chunk: [4]u8 = buf[position..][0..4].*;
    //         position += 4;

    //         const len = std.mem.readInt(u32, &len_chunk, .big); // length of the data
    //         defer position += len; // move position to after the chunk data

    //         const chunk_type = buf[(position)..(position + 4)]; // chunk type label
    //         position += 4;

    //         const chunk_data = buf[position..(position + len)];

    //         const chunk = PNG_Chunk{
    //             .length = len,
    //             .chunk_data = chunk_data,
    //             .chunk_type = chunk_type[0..4].*,
    //         };

    //         const crictical = chunk_type[0] >> 5 & 1 == 0;
    //         const public = chunk_type[1] >> 5 & 1 == 0;
    //         const std_png = chunk_type[2] >> 5 & 1 == 0;
    //         _ = chunk_type[3] >> 5 & 1 == 0; // ignore the safe to copy bit cuz we dont need it ig?
    //         // TODO CRC Algorithm

    //         if (!std_png) {
    //             break; // perhaps might just glitch out cuz i dont how to parse that stuff
    //         }
    //         if (chunk.is_img_header() and !first_chunk) {
    //             std.debug.print("why is the header not the first chunk!?", .{});
    //             break;
    //         } else {
    //             std.debug.print("len of {s} chunk: {d}, critical: {}, public: {}\n", .{ chunk_type, len, crictical, public });

    //             if (chunk.is_img_data()) {
    //                 std.debug.print("{s}\n", .{chunk_data});
    //             }

    //             if (chunk.is_img_end() and len == 0) {
    //                 break;
    //             }

    //             if (chunk.is_img_header()) {
    //                 self = @as(Image, @bitCast(chunk_data[0..13].*));

    //                 // seperately reading width/height cuz for some reason they are not big endian
    //                 self.width = std.mem.readInt(u32, chunk_data[0..4], .big); // width of the image
    //                 self.height = std.mem.readInt(u32, chunk_data[4..8], .big); // height of the image
    //                 // self.bitdepth = chunk_data[8];
    //                 // // TODO: PLTE Chunk required for color type = 3; does not check currently
    //                 // self.color_type = chunk_data[9];
    //                 // self.compression_method = chunk_data[10];
    //                 // self.filter_method = chunk_data[11];
    //                 // self.interlace_method = chunk_data[12];

    //                 if (self.filter_method != 0) {
    //                     return error.UnknownFilterMethod;
    //                 }
    //                 if (self.compression_method != 0) {
    //                     return error.UnkownCompressionMethod;
    //                 }

    //                 const is_bit_depth_ok = switch (self.color_type) {
    //                     0 => (self.bitdepth == 1 or self.bitdepth == 2 or self.bitdepth == 4 or self.bitdepth == 8 or self.bitdepth == 16),
    //                     2, 4, 6 => (self.bitdepth == 8 or self.bitdepth == 16),
    //                     3 => (self.bitdepth == 1 or self.bitdepth == 2 or self.bitdepth == 4 or self.bitdepth == 8),
    //                     else => false,
    //                 };

    //                 if (!is_bit_depth_ok) {
    //                     std.debug.print("The files corrupted cuz the bitdepths all messed up; color type: {}, bitdepth: {}\n", .{ self.color_type, self.bitdepth });
    //                     return error.WrongBitdepth;
    //                 }
    //                 first_chunk = false;
    //             }
    //         }
    //     }

    //     if (position > 4096) {
    //         position_bklog = position - 4096;
    //     } else {
    //         position_bklog = 0;
    //     }
    // }
    // std.debug.print("image: {any}\n", .{self});
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
