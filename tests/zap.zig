//! Compatibility with Zap's typed Mustache tests.
//! Source: zigzap/zap, f6099ecec496c7ec623c5913baa5b6b5da2e883d,
//! src/tests/test_mustache.zig, testtemplate.html and testpartial.html.
//! Copyright (c) 2023 Rene Schallner. MIT; see spec/LICENSE-ZAP.
const std = @import("std");
const mustache = @import("mustache");

fn parse(allocator: std.mem.Allocator, text: []const u8) !mustache.Template {
    const result = try mustache.parseText(allocator, text, .{}, .{
        .copy_strings = false,
        .features = .{ .lambdas = .disabled },
    });
    return switch (result) {
        .success => |template| template,
        .parse_error => error.TemplateParseFailure,
    };
}

const User = struct {
    name: []const u8,
    id: isize,
};

const users = [_]User{
    .{ .name = "Rene", .id = 1 },
    .{ .name = "Caro", .id = 6 },
};

const source = "{{=<< >>=}}* Users:\n<<#users>><<id>>. <<& name>> (<<name>>)\n<</users>>\nNested: <<& nested.item >>.";
const expected = "* Users:\n1. Rene (Rene)\n6. Caro (Caro)\nNested: nesting works.";

test "Zap in-memory Mustache preserves typed array output" {
    const template = try parse(std.testing.allocator, source);
    defer template.deinit(std.testing.allocator);
    var storage: [expected.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try mustache.renderBounded(template, .{
        .users = users,
        .nested = .{ .item = "nesting works" },
    }, &writer, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "Zap in-memory Mustache also accepts a borrowed typed slice" {
    const template = try parse(std.testing.allocator, source);
    defer template.deinit(std.testing.allocator);
    var storage: [expected.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try mustache.renderBounded(template, .{
        .users = @as([]const User, &users),
        .nested = .{ .item = @as([]const u8, "nesting works") },
    }, &writer, .{});
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test "Zap file-style partial resets delimiters and preserves final newline" {
    // Explicit startup registration replaces Zap's implicit filesystem lookup.
    const template = try parse(std.testing.allocator, "{{=<< >>=}}* Users:\n<<#users>><<id>>. <<& name>> (<<name>>)\n<</users>>\n<<>testpartial.html>>\n");
    defer template.deinit(std.testing.allocator);
    const partial = try parse(std.testing.allocator, "Nested: {{& nested.item }}.\n");
    defer partial.deinit(std.testing.allocator);
    var storage: [expected.len + 1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try mustache.renderPartialsBounded(template, .{.{ "testpartial.html", partial }}, .{
        .users = users,
        .nested = .{ .item = "nesting works" },
    }, &writer, .{});
    try std.testing.expectEqualStrings(expected ++ "\n", writer.buffered());
}

test "cached Zap render does not use its template allocator" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const template = try parse(allocator, source);
    defer template.deinit(allocator);
    const setup_allocations = failing.alloc_index;
    failing.fail_index = setup_allocations;
    failing.resize_fail_index = failing.resize_index;

    var storage: [expected.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    try mustache.renderBounded(template, .{
        .users = users,
        .nested = .{ .item = "nesting works" },
    }, &writer, .{});

    try std.testing.expectEqualStrings(expected, writer.buffered());
    try std.testing.expectEqual(setup_allocations, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
}
