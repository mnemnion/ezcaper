//! Ezcaper: escape control characters and strings.
//!
//! This is a simple, self-contained module designed to do one thing: Escape strings
//! and characters of arbitrary UTF-8.
//!
//! The brains of the operation is the oddly-specific function whichControlKind, which
//! answer with the enums `.control`, `.format`, and `.normal`.  This allows for strings
//! and codepoints to have different behavior for format characters: escaped as codepoints
//! and printed directly as strings.  This lets Farmer Bob "👨🏻‍🌾" print as a single
//! grapheme, while the ZWJ in Farmer Bob, in isolation, becomes '\u{200d}'.
//!
//! The functions are code-generated from the Unicode Character Database data for
//! version 17.0, and will be updated upon the occasion of subsequent versions
//! of Unicode.  It uses a master switch to separate codepoints by power-of-two,
//! this is likely somewhat less efficient than the lookup table employed by `zg`,
//! with the compensating advantage that it's pure code with no allocations.
//!
//! These are used to power a few structs, intended to be used in formatted printing.
//! EscChar will print a single u21, using either `{}` or `{u}` as the format string.
//! If it receives `u` it will print the character 'bare', otherwise it will surround
//! it with a pair of quotes and write `'` as `\'`.  This will throw an error if the
//! codepoint is too large.
//!
//! There are two structs for printing escaped strings: EscStringExact and EscStringLossy.
//! EscStringExact will print `\x` codes for any invalid Unicode data, while EscStringLossy
//! will print the Unicode Replacement Character U+FFFD for any invalid sequences, following
//! the recommended approach to substitution in the Unicode Standard.
//!
//! Both may be called with `{}` and `{s}`, with the same sort of outcome: `s` will print the
//! string without quotes, while the bare option will print the string in double-quotes and
//! escape a double quote as `\"`.  Both use the escape sequences `\t`, `\r`, and `\n`, print
//! ASCII C0 codes as `\xXX`, and all other escaped values in the `\u{XXXX}` format.
//!
//! It is a bug if the string produced by EscStringExact does not read into Zig with a byte-
//! identical result to the source string.  It is *not* a bug if zig fmt formats the result
//! string differently from ezcaper.
//!
//! Note that EscChar will escape surrogate codepoints, which is not (currently) valid in
//! Zig source code.  The string printers will replace or byte-print surrogates, respectively,
//! and this will change if and when escaped surrogates become valid in Zig strings, see
//! issue #20270.
//!
//! For convenient formatting, these structs can be created with helper functions `escChar`,
//! `escStringExact`, and `escStringLossy`.  Example use:
//!
//! ```zig
//! std.debug.print("a string: {} and a char {u}", .{escStringExact(str), escChar(c)});
//! ```
//!
//! This module has `runerip` as a dependency, because the API makes handling both kinds of
//! string print easier.  This dependency may be removed at some future point.
//!

const std = @import("std");

const runerip = @import("runerip");

/// Escape a Unicode scalar value for formatted printing.
pub fn escChar(c: u21) EscChar {
    return .{ .c = c };
}

/// Escape a string, replacing invalid UTF-8 with U+FFFD.
pub fn escStringLossy(str: []const u8) EscStringLossy {
    return .{ .str = str };
}

/// Escape a string, printing invalid bytes as \xXX.
pub fn escStringExact(str: []const u8) EscStringExact {
    return .{ .str = str };
}

/// A struct for formatting `u21` characters.
pub const EscChar = struct {
    c: u21,

    pub fn format(
        char: EscChar,
        fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len == 0) {
            try writer.writeByte('\'');
        } else if (fmt.len != 1 or fmt[0] != 'u') {
            std.debug.panic("Invalid format string \"{s}\" for EscChar", .{fmt});
        }
        if (isControl(char.c)) {
            if (char.c < 0x80) {
                switch (char.c) {
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.print("\\x{x:0>2}", .{char.c}),
                }
            } else if (char.c <= 0x10ffff) {
                try writer.print("\\u{{{x}}}", .{char.c});
            } else {
                return error.CodepointTooLarge;
            }
        } else {
            if (fmt.len == 0 and char.c == '\'') {
                try writer.writeAll("\'");
            } else {
                try writer.print("{u}", .{char.c});
            }
        }
        if (fmt.len == 0) {
            try writer.writeByte('\'');
        }
    }
};

/// Escaped printer for strings.  Replaces invalid sequences with
/// U+FFFD.
pub const EscStringLossy = struct {
    str: []const u8,

    pub fn format(
        sequence: EscStringLossy,
        fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try stringEscaperLossy(fmt, sequence.str, writer);
    }
};

pub const EscStringExact = struct {
    str: []const u8,

    pub fn format(
        sequence: EscStringExact,
        fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try stringEscaperExact(fmt, sequence.str, writer);
    }
};

fn stringEscaperLossy(fmt: []const u8, seq: []const u8, writer: anytype) !void {
    if (fmt.len == 0) {
        try writer.writeByte('"');
    } else if (fmt.len != 1 or fmt[0] != 's') {
        std.debug.panic("Invalid format string \"{s}\" for EscStringLossy", .{fmt});
    }
    var cursor: usize = 0;
    var start: usize = 0;
    while (cursor < seq.len) {
        const this_cursor = cursor;
        const cp = runerip.decodeRuneCursor(seq, &cursor) catch {
            try writer.writeAll(seq[start..this_cursor]);
            try writer.writeAll("\u{fffd}");
            if (this_cursor == cursor) {
                cursor += 1;
            }
            start = cursor;
            continue;
        };
        switch (whichControlKind(cp)) {
            .control => {
                try writer.writeAll(seq[start..this_cursor]);
                start = cursor;
                if (cp < 0x80) {
                    switch (cp) {
                        '\t' => try writer.writeAll("\\t"),
                        '\r' => try writer.writeAll("\\r"),
                        '\n' => try writer.writeAll("\\n"),
                        else => try writer.print("\\x{x:0>2}", .{cp}),
                    }
                } else {
                    try writer.print("\\u{{{x}}}", .{cp});
                }
            },
            .format, .normal => {
                if (fmt.len == 0 and (cp == '\\' or cp == '"')) {
                    try writer.writeAll(seq[start..this_cursor]);
                    start = cursor;
                    try writer.print("\\{u}", .{cp});
                }
            },
        }
    }
    try writer.writeAll(seq[start..seq.len]);
    if (fmt.len == 0) {
        try writer.writeByte('"');
    }
}

fn stringEscaperExact(fmt: []const u8, seq: []const u8, writer: anytype) !void {
    if (fmt.len == 0) {
        try writer.writeByte('"');
    } else if (fmt.len != 1 or fmt[0] != 's') {
        std.debug.panic("Invalid format string \"{s}\" for EscStringLossy", .{fmt});
    }
    var cursor: usize = 0;
    var start: usize = 0;
    while (cursor < seq.len) {
        const this_cursor = cursor;
        const cp = runerip.decodeRuneCursor(seq, &cursor) catch {
            try writer.writeAll(seq[start..this_cursor]);
            if (this_cursor == cursor) {
                cursor += 1;
            }
            for (this_cursor..cursor) |c| {
                try writer.print("\\x{x:0>2}", .{seq[c]});
            }
            start = cursor;
            continue;
        };
        switch (whichControlKind(cp)) {
            .control => {
                try writer.writeAll(seq[start..this_cursor]);
                start = cursor;
                if (cp < 0x80) {
                    switch (cp) {
                        '\t' => try writer.writeAll("\\t"),
                        '\r' => try writer.writeAll("\\r"),
                        '\n' => try writer.writeAll("\\n"),
                        else => try writer.print("\\x{x:0>2}", .{cp}),
                    }
                } else {
                    try writer.print("\\u{{{x}}}", .{cp});
                }
            },
            .format, .normal => {
                if (fmt.len == 0 and (cp == '\\' or cp == '"')) {
                    try writer.writeAll(seq[start..this_cursor]);
                    start = cursor;
                    try writer.print("\\{u}", .{cp});
                }
            },
        }
    }
    try writer.writeAll(seq[start..seq.len]);
    if (fmt.len == 0) {
        try writer.writeByte('"');
    }
}

/// Enumeration of the relevant control categories.
pub const ControlKind = enum {
    normal,
    format,
    control,
};

pub fn isControl(cp: u21) bool {
    return switch (whichControlKind(cp)) {
        .normal => false,
        .format, .control => true,
    };
}

//| Tests

const expectEqualStrings = std.testing.expectEqualStrings;

test escChar {
    const allocator = std.testing.allocator;
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var writer = out_array.writer();
    try writer.print("{}", .{escChar('!')});
    try expectEqualStrings("'!'", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{u}", .{escChar('!')});
    try expectEqualStrings("!", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{}", .{escChar('\t')});
    try expectEqualStrings("'\\t'", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{}", .{escChar('\x05')});
    try expectEqualStrings("'\\x05'", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{}", .{escChar('\u{200d}')});
    try expectEqualStrings("'\\u{200d}'", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{u}", .{escChar('∅')});
    try expectEqualStrings("∅", out_array.items);
    out_array.shrinkRetainingCapacity(0);
}

test escStringLossy {
    const allocator = std.testing.allocator;
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var writer = out_array.writer();
    try writer.print("{s}", .{escStringLossy("Farmer 👨🏻‍🌾 Bob")});
    try expectEqualStrings("Farmer 👨🏻‍🌾 Bob", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{s}", .{escStringLossy("bad \xc0 byte")});
    try expectEqualStrings("bad \u{fffd} byte", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{}", .{escStringLossy("\t\x05\u{81}")});
    try expectEqualStrings("\"\\t\\x05\\u{81}\"", out_array.items);
    out_array.shrinkRetainingCapacity(0);
}

test escStringExact {
    const allocator = std.testing.allocator;
    var out_array = std.ArrayList(u8).init(allocator);
    defer out_array.deinit();
    var writer = out_array.writer();
    try writer.print("{s}", .{escStringExact("Farmer 👨🏻‍🌾 Bob")});
    try expectEqualStrings("Farmer 👨🏻‍🌾 Bob", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{s}", .{escStringExact("bad \xc0 byte")});
    try expectEqualStrings("bad \\xc0 byte", out_array.items);
    out_array.shrinkRetainingCapacity(0);
    try writer.print("{}", .{escStringExact("Truncated \xf0\x9f\x98 😀")});
    try expectEqualStrings("\"Truncated \\xf0\\x9f\\x98 😀\"", out_array.items);
    out_array.shrinkRetainingCapacity(0);
}

//| Generated Code, do not change.  Any bugs here need to be fixed in
//| the script which creates it.

/// Answer whether the codepoint is a C-series control,
/// format, or a normal codepoint.
pub fn whichControlKind(cp: u21) ControlKind {
    return switch (cp) {
        0x0000...0x007F => whichControlImpl0(cp),
        0x0080...0x00FF => whichControlImpl1(cp),
        0x0100...0x01FF => whichControlImpl2(cp),
        0x0200...0x03FF => whichControlImpl4(cp),
        0x0400...0x07FF => whichControlImpl8(cp),
        0x0800...0x0FFF => whichControlImpl16(cp),
        0x1000...0x1FFF => whichControlImpl32(cp),
        0x2000...0x3FFF => whichControlImpl64(cp),
        0x4000...0x7FFF => whichControlImpl128(cp),
        0x8000...0xFFFF => whichControlImpl256(cp),
        0x10000...0x1FFFF => whichControlImpl512(cp),
        0x20000...0x3FFFF => whichControlImpl1024(cp),
        0x40000...0x7FFFF => whichControlImpl2048(cp),
        0x80000...0xFFFFF => whichControlImpl4096(cp),
        0x100000...0x1FFFFF => whichControlImpl8192(cp),
    };
}

/// Implementation for control determination in range 0x0000...0x007F
fn whichControlImpl0(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x0000...0x001F, 0x007F,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x0080...0x00FF
fn whichControlImpl1(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x0080...0x009F => .control,
        0x00AD,  => .format,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x0100...0x01FF
fn whichControlImpl2(cp: u21) ControlKind {
    _ = cp;
    return .normal;
}
/// Implementation for control determination in range 0x0200...0x03FF
fn whichControlImpl4(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x0378...0x0379, 0x0380...0x0383, 0x038B, 0x038D, 0x03A2,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x0400...0x07FF
fn whichControlImpl8(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x0530, 0x0557...0x0558, 0x058B...0x058C, 0x0590, 0x05C8...0x05CF,
        0x05EB...0x05EE, 0x05F5...0x05FF => .control,
        0x0600...0x0605, 0x061C, 0x06DD => .format,
        0x070E => .control,
        0x070F => .format,
        0x074B...0x074C, 0x07B2...0x07BF, 0x07FB...0x07FC,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x0800...0x0FFF
fn whichControlImpl16(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x082E...0x082F, 0x083F, 0x085C...0x085D, 0x085F, 0x086B...0x086F, 0x088F,
         => .control,
        0x0890...0x0891 => .format,
        0x0892...0x0896 => .control,
        0x08E2 => .format,
        0x0984, 0x098D...0x098E, 0x0991...0x0992, 0x09A9, 0x09B1, 0x09B3...0x09B5,
        0x09BA...0x09BB, 0x09C5...0x09C6, 0x09C9...0x09CA, 0x09CF...0x09D6,
        0x09D8...0x09DB, 0x09DE, 0x09E4...0x09E5, 0x09FF...0x0A00, 0x0A04,
        0x0A0B...0x0A0E, 0x0A11...0x0A12, 0x0A29, 0x0A31, 0x0A34, 0x0A37,
        0x0A3A...0x0A3B, 0x0A3D, 0x0A43...0x0A46, 0x0A49...0x0A4A, 0x0A4E...0x0A50,
        0x0A52...0x0A58, 0x0A5D, 0x0A5F...0x0A65, 0x0A77...0x0A80, 0x0A84, 0x0A8E,
        0x0A92, 0x0AA9, 0x0AB1, 0x0AB4, 0x0ABA...0x0ABB, 0x0AC6, 0x0ACA, 0x0ACE...0x0ACF,
        0x0AD1...0x0ADF, 0x0AE4...0x0AE5, 0x0AF2...0x0AF8, 0x0B00, 0x0B04,
        0x0B0D...0x0B0E, 0x0B11...0x0B12, 0x0B29, 0x0B31, 0x0B34, 0x0B3A...0x0B3B,
        0x0B45...0x0B46, 0x0B49...0x0B4A, 0x0B4E...0x0B54, 0x0B58...0x0B5B, 0x0B5E,
        0x0B64...0x0B65, 0x0B78...0x0B81, 0x0B84, 0x0B8B...0x0B8D, 0x0B91,
        0x0B96...0x0B98, 0x0B9B, 0x0B9D, 0x0BA0...0x0BA2, 0x0BA5...0x0BA7,
        0x0BAB...0x0BAD, 0x0BBA...0x0BBD, 0x0BC3...0x0BC5, 0x0BC9, 0x0BCE...0x0BCF,
        0x0BD1...0x0BD6, 0x0BD8...0x0BE5, 0x0BFB...0x0BFF, 0x0C0D, 0x0C11, 0x0C29,
        0x0C3A...0x0C3B, 0x0C45, 0x0C49, 0x0C4E...0x0C54, 0x0C57, 0x0C5B...0x0C5C,
        0x0C5E...0x0C5F, 0x0C64...0x0C65, 0x0C70...0x0C76, 0x0C8D, 0x0C91, 0x0CA9,
        0x0CB4, 0x0CBA...0x0CBB, 0x0CC5, 0x0CC9, 0x0CCE...0x0CD4, 0x0CD7...0x0CDC,
        0x0CDF, 0x0CE4...0x0CE5, 0x0CF0, 0x0CF4...0x0CFF, 0x0D0D, 0x0D11, 0x0D45, 0x0D49,
        0x0D50...0x0D53, 0x0D64...0x0D65, 0x0D80, 0x0D84, 0x0D97...0x0D99, 0x0DB2,
        0x0DBC, 0x0DBE...0x0DBF, 0x0DC7...0x0DC9, 0x0DCB...0x0DCE, 0x0DD5, 0x0DD7,
        0x0DE0...0x0DE5, 0x0DF0...0x0DF1, 0x0DF5...0x0E00, 0x0E3B...0x0E3E,
        0x0E5C...0x0E80, 0x0E83, 0x0E85, 0x0E8B, 0x0EA4, 0x0EA6, 0x0EBE...0x0EBF, 0x0EC5,
        0x0EC7, 0x0ECF, 0x0EDA...0x0EDB, 0x0EE0...0x0EFF, 0x0F48, 0x0F6D...0x0F70,
        0x0F98, 0x0FBD, 0x0FCD, 0x0FDB...0x0FFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x1000...0x1FFF
fn whichControlImpl32(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x10C6, 0x10C8...0x10CC, 0x10CE...0x10CF, 0x1249, 0x124E...0x124F, 0x1257,
        0x1259, 0x125E...0x125F, 0x1289, 0x128E...0x128F, 0x12B1, 0x12B6...0x12B7,
        0x12BF, 0x12C1, 0x12C6...0x12C7, 0x12D7, 0x1311, 0x1316...0x1317,
        0x135B...0x135C, 0x137D...0x137F, 0x139A...0x139F, 0x13F6...0x13F7,
        0x13FE...0x13FF, 0x169D...0x169F, 0x16F9...0x16FF, 0x1716...0x171E,
        0x1737...0x173F, 0x1754...0x175F, 0x176D, 0x1771, 0x1774...0x177F,
        0x17DE...0x17DF, 0x17EA...0x17EF, 0x17FA...0x17FF => .control,
        0x180E => .format,
        0x181A...0x181F, 0x1879...0x187F, 0x18AB...0x18AF, 0x18F6...0x18FF, 0x191F,
        0x192C...0x192F, 0x193C...0x193F, 0x1941...0x1943, 0x196E...0x196F,
        0x1975...0x197F, 0x19AC...0x19AF, 0x19CA...0x19CF, 0x19DB...0x19DD,
        0x1A1C...0x1A1D, 0x1A5F, 0x1A7D...0x1A7E, 0x1A8A...0x1A8F, 0x1A9A...0x1A9F,
        0x1AAE...0x1AAF, 0x1ACF...0x1AFF, 0x1B4D, 0x1BF4...0x1BFB, 0x1C38...0x1C3A,
        0x1C4A...0x1C4C, 0x1C8B...0x1C8F, 0x1CBB...0x1CBC, 0x1CC8...0x1CCF,
        0x1CFB...0x1CFF, 0x1F16...0x1F17, 0x1F1E...0x1F1F, 0x1F46...0x1F47,
        0x1F4E...0x1F4F, 0x1F58, 0x1F5A, 0x1F5C, 0x1F5E, 0x1F7E...0x1F7F, 0x1FB5, 0x1FC5,
        0x1FD4...0x1FD5, 0x1FDC, 0x1FF0...0x1FF1, 0x1FF5, 0x1FFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x2000...0x3FFF
fn whichControlImpl64(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064 => .format,
        0x2065 => .control,
        0x2066...0x206F => .format,
        0x2072...0x2073, 0x208F, 0x209D...0x209F, 0x20C1...0x20CF, 0x20F1...0x20FF,
        0x218C...0x218F, 0x242A...0x243F, 0x244B...0x245F, 0x2B74...0x2B75, 0x2B96,
        0x2CF4...0x2CF8, 0x2D26, 0x2D28...0x2D2C, 0x2D2E...0x2D2F, 0x2D68...0x2D6E,
        0x2D71...0x2D7E, 0x2D97...0x2D9F, 0x2DA7, 0x2DAF, 0x2DB7, 0x2DBF, 0x2DC7, 0x2DCF,
        0x2DD7, 0x2DDF, 0x2E5E...0x2E7F, 0x2E9A, 0x2EF4...0x2EFF, 0x2FD6...0x2FEF,
        0x3040, 0x3097...0x3098, 0x3100...0x3104, 0x3130, 0x318F, 0x31E6...0x31EE,
        0x321F,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x4000...0x7FFF
fn whichControlImpl128(cp: u21) ControlKind {
    _ = cp;
    return .normal;
}
/// Implementation for control determination in range 0x8000...0xFFFF
fn whichControlImpl256(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0xA48D...0xA48F, 0xA4C7...0xA4CF, 0xA62C...0xA63F, 0xA6F8...0xA6FF,
        0xA7CE...0xA7CF, 0xA7D2, 0xA7D4, 0xA7DD...0xA7F1, 0xA82D...0xA82F,
        0xA83A...0xA83F, 0xA878...0xA87F, 0xA8C6...0xA8CD, 0xA8DA...0xA8DF,
        0xA954...0xA95E, 0xA97D...0xA97F, 0xA9CE, 0xA9DA...0xA9DD, 0xA9FF,
        0xAA37...0xAA3F, 0xAA4E...0xAA4F, 0xAA5A...0xAA5B, 0xAAC3...0xAADA,
        0xAAF7...0xAB00, 0xAB07...0xAB08, 0xAB0F...0xAB10, 0xAB17...0xAB1F, 0xAB27,
        0xAB2F, 0xAB6C...0xAB6F, 0xABEE...0xABEF, 0xABFA...0xABFF, 0xD7A4...0xD7AF,
        0xD7C7...0xD7CA, 0xD7FC...0xF8FF, 0xFA6E...0xFA6F, 0xFADA...0xFAFF,
        0xFB07...0xFB12, 0xFB18...0xFB1C, 0xFB37, 0xFB3D, 0xFB3F, 0xFB42, 0xFB45,
        0xFBC3...0xFBD2, 0xFD90...0xFD91, 0xFDC8...0xFDCE, 0xFDD0...0xFDEF,
        0xFE1A...0xFE1F, 0xFE53, 0xFE67, 0xFE6C...0xFE6F, 0xFE75, 0xFEFD...0xFEFE,
         => .control,
        0xFEFF => .format,
        0xFF00, 0xFFBF...0xFFC1, 0xFFC8...0xFFC9, 0xFFD0...0xFFD1, 0xFFD8...0xFFD9,
        0xFFDD...0xFFDF, 0xFFE7, 0xFFEF...0xFFF8 => .control,
        0xFFF9...0xFFFB => .format,
        0xFFFE...0xFFFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x10000...0x1FFFF
fn whichControlImpl512(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x1000C, 0x10027, 0x1003B, 0x1003E, 0x1004E...0x1004F, 0x1005E...0x1007F,
        0x100FB...0x100FF, 0x10103...0x10106, 0x10134...0x10136, 0x1018F,
        0x1019D...0x1019F, 0x101A1...0x101CF, 0x101FE...0x1027F, 0x1029D...0x1029F,
        0x102D1...0x102DF, 0x102FC...0x102FF, 0x10324...0x1032C, 0x1034B...0x1034F,
        0x1037B...0x1037F, 0x1039E, 0x103C4...0x103C7, 0x103D6...0x103FF,
        0x1049E...0x1049F, 0x104AA...0x104AF, 0x104D4...0x104D7, 0x104FC...0x104FF,
        0x10528...0x1052F, 0x10564...0x1056E, 0x1057B, 0x1058B, 0x10593, 0x10596,
        0x105A2, 0x105B2, 0x105BA, 0x105BD...0x105BF, 0x105F4...0x105FF,
        0x10737...0x1073F, 0x10756...0x1075F, 0x10768...0x1077F, 0x10786, 0x107B1,
        0x107BB...0x107FF, 0x10806...0x10807, 0x10809, 0x10836, 0x10839...0x1083B,
        0x1083D...0x1083E, 0x10856, 0x1089F...0x108A6, 0x108B0...0x108DF, 0x108F3,
        0x108F6...0x108FA, 0x1091C...0x1091E, 0x1093A...0x1093E, 0x10940...0x1097F,
        0x109B8...0x109BB, 0x109D0...0x109D1, 0x10A04, 0x10A07...0x10A0B, 0x10A14,
        0x10A18, 0x10A36...0x10A37, 0x10A3B...0x10A3E, 0x10A49...0x10A4F,
        0x10A59...0x10A5F, 0x10AA0...0x10ABF, 0x10AE7...0x10AEA, 0x10AF7...0x10AFF,
        0x10B36...0x10B38, 0x10B56...0x10B57, 0x10B73...0x10B77, 0x10B92...0x10B98,
        0x10B9D...0x10BA8, 0x10BB0...0x10BFF, 0x10C49...0x10C7F, 0x10CB3...0x10CBF,
        0x10CF3...0x10CF9, 0x10D28...0x10D2F, 0x10D3A...0x10D3F, 0x10D66...0x10D68,
        0x10D86...0x10D8D, 0x10D90...0x10E5F, 0x10E7F, 0x10EAA, 0x10EAE...0x10EAF,
        0x10EB2...0x10EC1, 0x10EC5...0x10EFB, 0x10F28...0x10F2F, 0x10F5A...0x10F6F,
        0x10F8A...0x10FAF, 0x10FCC...0x10FDF, 0x10FF7...0x10FFF, 0x1104E...0x11051,
        0x11076...0x1107E => .control,
        0x110BD => .format,
        0x110C3...0x110CC => .control,
        0x110CD => .format,
        0x110CE...0x110CF, 0x110E9...0x110EF, 0x110FA...0x110FF, 0x11135,
        0x11148...0x1114F, 0x11177...0x1117F, 0x111E0, 0x111F5...0x111FF, 0x11212,
        0x11242...0x1127F, 0x11287, 0x11289, 0x1128E, 0x1129E, 0x112AA...0x112AF,
        0x112EB...0x112EF, 0x112FA...0x112FF, 0x11304, 0x1130D...0x1130E,
        0x11311...0x11312, 0x11329, 0x11331, 0x11334, 0x1133A, 0x11345...0x11346,
        0x11349...0x1134A, 0x1134E...0x1134F, 0x11351...0x11356, 0x11358...0x1135C,
        0x11364...0x11365, 0x1136D...0x1136F, 0x11375...0x1137F, 0x1138A,
        0x1138C...0x1138D, 0x1138F, 0x113B6, 0x113C1, 0x113C3...0x113C4, 0x113C6,
        0x113CB, 0x113D6, 0x113D9...0x113E0, 0x113E3...0x113FF, 0x1145C,
        0x11462...0x1147F, 0x114C8...0x114CF, 0x114DA...0x1157F, 0x115B6...0x115B7,
        0x115DE...0x115FF, 0x11645...0x1164F, 0x1165A...0x1165F, 0x1166D...0x1167F,
        0x116BA...0x116BF, 0x116CA...0x116CF, 0x116E4...0x116FF, 0x1171B...0x1171C,
        0x1172C...0x1172F, 0x11747...0x117FF, 0x1183C...0x1189F, 0x118F3...0x118FE,
        0x11907...0x11908, 0x1190A...0x1190B, 0x11914, 0x11917, 0x11936,
        0x11939...0x1193A, 0x11947...0x1194F, 0x1195A...0x1199F, 0x119A8...0x119A9,
        0x119D8...0x119D9, 0x119E5...0x119FF, 0x11A48...0x11A4F, 0x11AA3...0x11AAF,
        0x11AF9...0x11AFF, 0x11B0A...0x11BBF, 0x11BE2...0x11BEF, 0x11BFA...0x11BFF,
        0x11C09, 0x11C37, 0x11C46...0x11C4F, 0x11C6D...0x11C6F, 0x11C90...0x11C91,
        0x11CA8, 0x11CB7...0x11CFF, 0x11D07, 0x11D0A, 0x11D37...0x11D39, 0x11D3B,
        0x11D3E, 0x11D48...0x11D4F, 0x11D5A...0x11D5F, 0x11D66, 0x11D69, 0x11D8F,
        0x11D92, 0x11D99...0x11D9F, 0x11DAA...0x11EDF, 0x11EF9...0x11EFF, 0x11F11,
        0x11F3B...0x11F3D, 0x11F5B...0x11FAF, 0x11FB1...0x11FBF, 0x11FF2...0x11FFE,
        0x1239A...0x123FF, 0x1246F, 0x12475...0x1247F, 0x12544...0x12F8F,
        0x12FF3...0x12FFF => .control,
        0x13430...0x1343F => .format,
        0x13456...0x1345F, 0x143FB...0x143FF, 0x14647...0x160FF, 0x1613A...0x167FF,
        0x16A39...0x16A3F, 0x16A5F, 0x16A6A...0x16A6D, 0x16ABF, 0x16ACA...0x16ACF,
        0x16AEE...0x16AEF, 0x16AF6...0x16AFF, 0x16B46...0x16B4F, 0x16B5A, 0x16B62,
        0x16B78...0x16B7C, 0x16B90...0x16D3F, 0x16D7A...0x16E3F, 0x16E9B...0x16EFF,
        0x16F4B...0x16F4E, 0x16F88...0x16F8E, 0x16FA0...0x16FDF, 0x16FE5...0x16FEF,
        0x16FF2...0x16FFF, 0x187F8...0x187FF, 0x18CD6...0x18CFE, 0x18D09...0x1AFEF,
        0x1AFF4, 0x1AFFC, 0x1AFFF, 0x1B123...0x1B131, 0x1B133...0x1B14F,
        0x1B153...0x1B154, 0x1B156...0x1B163, 0x1B168...0x1B16F, 0x1B2FC...0x1BBFF,
        0x1BC6B...0x1BC6F, 0x1BC7D...0x1BC7F, 0x1BC89...0x1BC8F, 0x1BC9A...0x1BC9B,
         => .control,
        0x1BCA0...0x1BCA3 => .format,
        0x1BCA4...0x1CBFF, 0x1CCFA...0x1CCFF, 0x1CEB4...0x1CEFF, 0x1CF2E...0x1CF2F,
        0x1CF47...0x1CF4F, 0x1CFC4...0x1CFFF, 0x1D0F6...0x1D0FF, 0x1D127...0x1D128,
         => .control,
        0x1D173...0x1D17A => .format,
        0x1D1EB...0x1D1FF, 0x1D246...0x1D2BF, 0x1D2D4...0x1D2DF, 0x1D2F4...0x1D2FF,
        0x1D357...0x1D35F, 0x1D379...0x1D3FF, 0x1D455, 0x1D49D, 0x1D4A0...0x1D4A1,
        0x1D4A3...0x1D4A4, 0x1D4A7...0x1D4A8, 0x1D4AD, 0x1D4BA, 0x1D4BC, 0x1D4C4,
        0x1D506, 0x1D50B...0x1D50C, 0x1D515, 0x1D51D, 0x1D53A, 0x1D53F, 0x1D545,
        0x1D547...0x1D549, 0x1D551, 0x1D6A6...0x1D6A7, 0x1D7CC...0x1D7CD,
        0x1DA8C...0x1DA9A, 0x1DAA0, 0x1DAB0...0x1DEFF, 0x1DF1F...0x1DF24,
        0x1DF2B...0x1DFFF, 0x1E007, 0x1E019...0x1E01A, 0x1E022, 0x1E025,
        0x1E02B...0x1E02F, 0x1E06E...0x1E08E, 0x1E090...0x1E0FF, 0x1E12D...0x1E12F,
        0x1E13E...0x1E13F, 0x1E14A...0x1E14D, 0x1E150...0x1E28F, 0x1E2AF...0x1E2BF,
        0x1E2FA...0x1E2FE, 0x1E300...0x1E4CF, 0x1E4FA...0x1E5CF, 0x1E5FB...0x1E5FE,
        0x1E600...0x1E7DF, 0x1E7E7, 0x1E7EC, 0x1E7EF, 0x1E7FF, 0x1E8C5...0x1E8C6,
        0x1E8D7...0x1E8FF, 0x1E94C...0x1E94F, 0x1E95A...0x1E95D, 0x1E960...0x1EC70,
        0x1ECB5...0x1ED00, 0x1ED3E...0x1EDFF, 0x1EE04, 0x1EE20, 0x1EE23,
        0x1EE25...0x1EE26, 0x1EE28, 0x1EE33, 0x1EE38, 0x1EE3A, 0x1EE3C...0x1EE41,
        0x1EE43...0x1EE46, 0x1EE48, 0x1EE4A, 0x1EE4C, 0x1EE50, 0x1EE53,
        0x1EE55...0x1EE56, 0x1EE58, 0x1EE5A, 0x1EE5C, 0x1EE5E, 0x1EE60, 0x1EE63,
        0x1EE65...0x1EE66, 0x1EE6B, 0x1EE73, 0x1EE78, 0x1EE7D, 0x1EE7F, 0x1EE8A,
        0x1EE9C...0x1EEA0, 0x1EEA4, 0x1EEAA, 0x1EEBC...0x1EEEF, 0x1EEF2...0x1EFFF,
        0x1F02C...0x1F02F, 0x1F094...0x1F09F, 0x1F0AF...0x1F0B0, 0x1F0C0, 0x1F0D0,
        0x1F0F6...0x1F0FF, 0x1F1AE...0x1F1E5, 0x1F203...0x1F20F, 0x1F23C...0x1F23F,
        0x1F249...0x1F24F, 0x1F252...0x1F25F, 0x1F266...0x1F2FF, 0x1F6D8...0x1F6DB,
        0x1F6ED...0x1F6EF, 0x1F6FD...0x1F6FF, 0x1F777...0x1F77A, 0x1F7DA...0x1F7DF,
        0x1F7EC...0x1F7EF, 0x1F7F1...0x1F7FF, 0x1F80C...0x1F80F, 0x1F848...0x1F84F,
        0x1F85A...0x1F85F, 0x1F888...0x1F88F, 0x1F8AE...0x1F8AF, 0x1F8BC...0x1F8BF,
        0x1F8C2...0x1F8FF, 0x1FA54...0x1FA5F, 0x1FA6E...0x1FA6F, 0x1FA7D...0x1FA7F,
        0x1FA8A...0x1FA8E, 0x1FAC7...0x1FACD, 0x1FADD...0x1FADE, 0x1FAEA...0x1FAEF,
        0x1FAF9...0x1FAFF, 0x1FB93, 0x1FBFA...0x1FFFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x20000...0x3FFFF
fn whichControlImpl1024(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x2A6E0...0x2A6FF, 0x2B73A...0x2B73F, 0x2B81E...0x2B81F, 0x2CEA2...0x2CEAF,
        0x2EBE1...0x2EBEF, 0x2EE5E...0x2F7FF, 0x2FA1E...0x2FFFF, 0x3134B...0x3134F,
        0x323B0...0x3FFFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x40000...0x7FFFF
fn whichControlImpl2048(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x40000...0x7FFFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x80000...0xFFFFF
fn whichControlImpl4096(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x80000...0xE0000 => .control,
        0xE0001 => .format,
        0xE0002...0xE001F => .control,
        0xE0020...0xE007F => .format,
        0xE0080...0xE00FF, 0xE01F0...0xFFFFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}

/// Implementation for control determination in range 0x100000...0x1FFFFF
fn whichControlImpl8192(cp: u21) ControlKind {
    // zig fmt: off
    return switch(cp) {
        0x100000...0x10FFFF,  => .control,
        else => .normal,
    };
    // zig fmt: on
}
