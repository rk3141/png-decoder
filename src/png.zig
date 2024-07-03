const std = @import("std");

pub const PNG_SIGN = "\x89PNG\r\n\x1a\n"; // if the file starts with these bytes its a png

pub const PNG_Chunk = struct {
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

const FilterMethod = enum(u8) { None = 0, Sub, Up, Average, Paeth, _ };
fn paeth_predictor(a: u8, b: u8, c: u8) u8 {
    const p = (a +% b -% c);
    const pa = @abs(p -% a);
    const pb = @abs(p -% b);
    const pc = @abs(p -% c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}
const ColorType = enum(u8) {
    Grayscale = 0,
    RGB = 2,
    Pallete = 3, // PLTE
    GrayAlpha = 4,
    RGBA = 6,

    fn bytesPerPixel(self: ColorType) !u8 {
        return switch (self) {
            .RGB => 3,
            .GrayAlpha => 2,
            .RGBA => 4,
            else => return error.NonSupportedColorType,
        };
    }

    fn is_bitdepth_ok(self: ColorType, bitdepth: u8) bool {
        return switch (self) {
            .Grayscale => (bitdepth == 1 or bitdepth == 2 or bitdepth == 4 or bitdepth == 8 or bitdepth == 16),
            .Pallete => (bitdepth == 1 or bitdepth == 2 or bitdepth == 4 or bitdepth == 8),
            .RGB, .GrayAlpha, .RGBA => (bitdepth == 8 or bitdepth == 16),
        };
    }
};

pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    bitdepth: u8 = 0,
    color_type: ColorType = ColorType.Grayscale,
    compression_method: u8 = 0,
    filter_method: u8 = 0, // 0 stands for standard
    interlace_method: u8 = 0,

    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,

    idat: std.ArrayList(u8),
    raw_reconstruced_image: []u8 = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader) !Self {
        const idat = std.ArrayList(u8).init(allocator);
        var png_sign: [8]u8 = undefined;
        _ = try reader.read(&png_sign);
        if (!std.mem.eql(u8, PNG_SIGN, &png_sign)) {
            return error.NotAPNG;
        } else {
            return .{ .allocator = allocator, .reader = reader, .idat = idat };
        }
    }

    pub fn deinit(self: *Self) void {
        self.idat.deinit();
        self.allocator.free(self.raw_reconstruced_image);
    }

    fn read_chunk(self: *Self) !PNG_Chunk {
        var len_chunk: [4]u8 = undefined;
        _ = try self.reader.read(&len_chunk);

        const len = std.mem.readInt(u32, &len_chunk, .big); // length of the data

        var chunk_type: [4]u8 = undefined;
        _ = try self.reader.read(&chunk_type);

        const chunk_data = try self.allocator.alloc(u8, len);
        // defer self.allocator.free(chunk_data); MUST FREE CHUNK DATA IN self.read()
        _ = try self.reader.read(chunk_data);

        var _crc: [4]u8 = undefined;
        _ = try self.reader.read(&_crc);

        // const crictical = chunk_type[0] >> 5 & 1 == 0;
        // const public = chunk_type[1] >> 5 & 1 == 0;
        // _ = chunk_type[2] >> 5 & 1 == 0; // is standard png chunk type bit
        // _ = chunk_type[3] >> 5 & 1 == 0; // ignore the safe to copy bit cuz we dont need it ig?

        return PNG_Chunk{
            .length = len,
            .chunk_data = chunk_data,
            .chunk_type = chunk_type,
        };
    }

    pub fn read(self: *Self) !void {
        while (true) {
            const curr_chunk = try self.read_chunk();
            defer self.allocator.free(curr_chunk.chunk_data);

            if (curr_chunk.is_img_end()) {
                var deflated_idat = std.ArrayList(u8).init(self.allocator);
                defer deflated_idat.deinit();

                var idat_stream = std.io.fixedBufferStream(self.idat.items[0..]);
                const idat_reader = idat_stream.reader();

                try std.compress.zlib.decompress(idat_reader, deflated_idat.writer());

                const bytesPerPixel: usize = try self.color_type.bytesPerPixel();

                const stride = self.width * bytesPerPixel;

                var reconstucted_pixel_data = try self.allocator.alloc(u8, self.height * stride);
                // self.allocator.free(reconstucted_pixel_data); FREED in deinit

                var index: usize = 0;
                for (0..self.height) |j| {
                    const filter_type: FilterMethod = @enumFromInt(deflated_idat.items[index]);
                    index += 1;
                    for (0..stride) |i| {
                        // i + j * stride represents the postion of the byte in the 1D arr in terms of i, j
                        const filtered_byte: u9 = deflated_idat.items[index];
                        index += 1;

                        const a: u8 = if (i >= bytesPerPixel)
                            reconstucted_pixel_data[i + j * stride - bytesPerPixel]
                        else
                            0;
                        const b: u8 = if (j > 0) reconstucted_pixel_data[i + (j - 1) * stride] else 0;
                        const c: u8 = if (i >= bytesPerPixel and j > 0)
                            reconstucted_pixel_data[i + (j - 1) * stride - bytesPerPixel]
                        else
                            0;

                        const true_byte: u8 = @intCast(switch (filter_type) {
                            .None => filtered_byte,
                            .Sub => filtered_byte + a,
                            .Up => filtered_byte + b,
                            .Average => filtered_byte + @divFloor(@as(u32, @intCast(a)) + b, 2),
                            .Paeth => filtered_byte + paeth_predictor(a, b, c),
                            else => {
                                std.debug.print("{any}\n", .{filter_type});
                                return error.UnknownFilterMethod;
                            },
                        } & 0xff);
                        reconstucted_pixel_data[i + j * stride] = true_byte;
                    }
                }
                self.raw_reconstruced_image = reconstucted_pixel_data;
                break;
            } else if (curr_chunk.is_img_data()) {
                try self.idat.appendSlice(curr_chunk.chunk_data);
            } else if (curr_chunk.is_img_header()) {
                const width: [4]u8 = curr_chunk.chunk_data[0..4].*;
                const height: [4]u8 = curr_chunk.chunk_data[4..8].*;
                self.width = std.mem.readInt(u32, &width, .big); // width of the image
                self.height = std.mem.readInt(u32, &height, .big); // height of the image
                self.bitdepth = curr_chunk.chunk_data[8];
                // TODO: PLTE Chunk required for color type = 3; does not check currently
                self.color_type = @enumFromInt(curr_chunk.chunk_data[9]);
                self.compression_method = curr_chunk.chunk_data[10];
                self.filter_method = curr_chunk.chunk_data[11];
                self.interlace_method = curr_chunk.chunk_data[12];

                if (self.filter_method != 0) {
                    return error.UnknownFilterMethod;
                }
                if (self.compression_method != 0) {
                    return error.UnkownCompressionMethod;
                }

                if (!self.color_type.is_bitdepth_ok(self.bitdepth)) {
                    std.debug.print("The files corrupted cuz the bitdepths all messed up; color type: {any}, bitdepth: {}\n", .{ self.color_type, self.bitdepth });
                    return error.WrongBitdepth;
                }
            }
        }
    }

    pub fn from_file(allocator: std.mem.Allocator, file_name: []const u8) !Self {
        const file = try std.fs.cwd().openFile(file_name, .{});

        const freader = file.reader();

        var buf_reader = std.io.bufferedReader(freader);

        return try Self.init(allocator, buf_reader.reader().any());
    }
};
