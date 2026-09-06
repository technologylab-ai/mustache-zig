//! The six mandatory Mustache suites run without exclusions.
//! Fixture provenance and optional-module exclusions are in spec/README.md.
const std = @import("std");
const mustache = @import("mustache");
const Template = mustache.Template;

fn parse(source: []const u8) !Template {
    const result = try mustache.parseText(std.testing.allocator, source, .{}, .{
        .copy_strings = false,
        .features = .{ .lambdas = .disabled },
    });
    return switch (result) {
        .success => |template| template,
        .parse_error => |detail| {
            std.debug.print("Template parse: {s} at {d}:{d}\n", .{ @errorName(detail.parse_error), detail.lin, detail.col });
            return error.TemplateParseFailure;
        },
    };
}

// The renderer accepts a borrowed Value tree. JSON setup preserves numeric text
// as strings because Value has no numeric variant. Typed numbers also have
// independent coverage in zap.zig and the renderer's native-context tests.
fn convert(allocator: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!mustache.Value {
    return switch (value) {
        .null => .null,
        .bool => |boolean| .{ .bool = boolean },
        .string, .number_string => |string| .{ .string = string },
        .integer, .float => unreachable, // parse_numbers=false below.
        .array => |array| blk: {
            const items = try allocator.alloc(mustache.Value, array.items.len);
            for (array.items, items) |input, *output| output.* = try convert(allocator, input);
            break :blk .{ .list = items };
        },
        .object => |object| blk: {
            const fields = try allocator.alloc(mustache.Value.Field, object.count());
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                fields[index] = .{ .name = entry.key_ptr.*, .value = try convert(allocator, entry.value_ptr.*) };
            }
            break :blk .{ .map = fields };
        },
    };
}

fn runCase(value: std.json.Value) !void {
    const fields = value.object;
    const expected = fields.get("expected").?.string;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const data = try convert(arena.allocator(), fields.get("data").?);
    const template = try parse(fields.get("template").?.string);
    defer template.deinit(std.testing.allocator);
    const partial_values = fields.get("partials");

    // JSON owns every source string. Parsed partials stay alive until both
    // rendering passes finish. Setup allocations precede rendering.
    var partials = std.StringHashMap(Template).init(std.testing.allocator);
    defer {
        var iterator = partials.valueIterator();
        while (iterator.next()) |partial| partial.deinit(std.testing.allocator);
        partials.deinit();
    }
    if (partial_values) |values| {
        var iterator = values.object.iterator();
        while (iterator.next()) |entry| {
            const partial = try parse(entry.value_ptr.string);
            errdefer partial.deinit(std.testing.allocator);
            try partials.put(entry.key_ptr.*, partial);
        }
    }

    var storage: [4096]u8 = undefined;
    try std.testing.expect(expected.len <= storage.len);
    var writer: std.Io.Writer = .fixed(&storage);
    try mustache.renderPartialsBounded(template, partials, &data, &writer, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());

    // Every core case must also fit its exact output capacity, including zero.
    writer = .fixed(storage[0..expected.len]);
    try mustache.renderPartialsBounded(template, partials, &data, &writer, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

fn runSuite(comptime name: []const u8, comptime source: []const u8, expected_count: usize) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{ .parse_numbers = false });
    defer parsed.deinit();
    const cases = parsed.value.object.get("tests").?.array.items;
    try std.testing.expectEqual(expected_count, cases.len);

    var failed: usize = 0;
    for (cases) |case| {
        runCase(case) catch |err| {
            std.debug.print("\nMustache core {s}: {s}: {s}\n", .{
                name, case.object.get("name").?.string, @errorName(err),
            });
            failed += 1;
        };
    }
    if (failed != 0) {
        std.debug.print("Mustache core {s}: {d}/{d} cases failed\n", .{ name, failed, cases.len });
        return error.MustacheSpecFailures;
    }
}

test "Mustache core comments: 12 cases" {
    try runSuite("comments", @embedFile("spec/comments.json"), 12);
}

test "Mustache core delimiters: 14 cases" {
    try runSuite("delimiters", @embedFile("spec/delimiters.json"), 14);
}

test "Mustache core interpolation: 42 cases" {
    try runSuite("interpolation", @embedFile("spec/interpolation.json"), 42);
}

test "Mustache core inverted: 22 cases" {
    try runSuite("inverted", @embedFile("spec/inverted.json"), 22);
}

test "Mustache core partials: 12 cases" {
    try runSuite("partials", @embedFile("spec/partials.json"), 12);
}

test "Mustache core sections: 34 cases" {
    try runSuite("sections", @embedFile("spec/sections.json"), 34);
}
