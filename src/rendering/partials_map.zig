const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;

const testing = std.testing;
const assert = std.debug.assert;

const stdx = @import("../stdx.zig");

const mustache = @import("../mustache.zig");
const RenderOptions = mustache.options.RenderOptions;
const control = @import("budget.zig");

/// Partials map from a comptime known type
/// It works like a HashMap, but can be initialized from a tuple, slice or Hashmap
pub fn PartialsMapType(comptime TPartials: type, comptime comptime_options: RenderOptions) type {
    return struct {
        const PartialsMap = @This();

        pub const options: RenderOptions = comptime_options;

        pub const Template = switch (options) {
            .template => mustache.Template,
            .string, .file => []const u8,
        };

        allocator: ?Allocator,
        partials: TPartials,

        pub fn init(allocator: ?Allocator, partials: TPartials) PartialsMap {
            return .{
                .allocator = allocator,
                .partials = partials,
            };
        }

        pub fn isEmpty() bool {
            return switch (@typeInfo(TPartials)) {
                .void => true,
                .@"struct" => |info| info.is_tuple and info.field_names.len == 0,
                inline .array, .vector => |info| return info.len == 0,
                else => false,
            };
        }

        pub fn get(self: PartialsMap, key: []const u8) ?PartialsMap.Template {
            return self.getWithBudget(key, null);
        }

        pub fn getWithBudget(self: PartialsMap, key: []const u8, budget: ?*control.Budget) ?PartialsMap.Template {
            comptime validatePartials();
            if (!control.spend(budget, 1)) return null;

            if (comptime isValidTuple()) {
                return self.getFromTuple(key, budget);
            } else if (comptime isValidIndexable()) {
                return self.getFromIndexable(key, budget);
            } else if (comptime isValidMap()) {
                if (budget) |b| {
                    // Only standard string maps enter the bounded path.
                    // Custom lookup or capacity callbacks can execute application code.
                    if (comptime TPartials == std.StringHashMap(PartialsMap.Template) or
                        TPartials == std.StringHashMapUnmanaged(PartialsMap.Template))
                    {
                        // Meter empty slots and every possible key comparison.
                        if (!b.spend(self.partials.capacity())) return null;
                        var iterator = self.partials.iterator();
                        while (iterator.next()) |entry| {
                            if (!b.spend(1) or !b.spend(@min(entry.key_ptr.len, key.len))) return null;
                            if (std.mem.eql(u8, entry.key_ptr.*, key)) return entry.value_ptr.*;
                        }
                        return null;
                    } else {
                        _ = b.fail(error.UnsupportedFeature);
                        return null;
                    }
                }
                return self.getFromMap(key);
            } else if (comptime isEmpty()) {
                return null;
            } else {
                unreachable;
            }
        }

        fn getFromTuple(self: PartialsMap, key: []const u8, budget: ?*control.Budget) ?PartialsMap.Template {
            comptime assert(isValidTuple());

            if (comptime isPartialsTupleElement(TPartials)) {
                if (!control.spend(budget, @min(self.partials.@"0".len, key.len))) return null;
                return if (std.mem.eql(u8, self.partials.@"0", key)) self.partials.@"1" else null;
            } else {
                inline for (0..@typeInfo(TPartials).@"struct".field_names.len) |index| {
                    const item = self.partials[index];
                    if (!control.spend(budget, 1) or !control.spend(budget, @min(item.@"0".len, key.len))) return null;
                    if (std.mem.eql(u8, item.@"0", key)) return item.@"1";
                } else {
                    return null;
                }
            }
        }

        fn getFromIndexable(self: PartialsMap, key: []const u8, budget: ?*control.Budget) ?PartialsMap.Template {
            comptime assert(isValidIndexable());

            for (self.partials) |item| {
                if (!control.spend(budget, 1) or !control.spend(budget, @min(item[0].len, key.len))) return null;
                if (std.mem.eql(u8, item[0], key)) return item[1];
            }

            return null;
        }

        inline fn getFromMap(self: PartialsMap, key: []const u8) ?PartialsMap.Template {
            comptime assert(isValidMap());
            return self.partials.get(key);
        }

        fn validatePartials() void {
            comptime {
                if (!isValidTuple() and !isValidIndexable() and !isValidMap() and !isEmpty()) @compileError(
                    std.fmt.comptimePrint(
                        \\Invalid Partials type.
                        \\Expected a HashMap or a tuple containing Key/Value pairs
                        \\Key="[]const u8" and Value="{s}"
                        \\Found: "{s}"
                    , .{ @typeName(PartialsMap.Template), @typeName(TPartials) }),
                );
            }
        }

        fn isValidTuple() bool {
            comptime {
                if (stdx.isTuple(TPartials)) {
                    if (isPartialsTupleElement(TPartials)) {
                        return true;
                    } else {
                        for (@typeInfo(TPartials).@"struct".field_types) |field_type| {
                            if (!isPartialsTupleElement(field_type)) {
                                return false;
                            }
                        } else {
                            return true;
                        }
                    }
                }

                return false;
            }
        }

        fn isValidIndexable() bool {
            comptime {
                if (stdx.isIndexable(TPartials) and !stdx.isTuple(TPartials)) {
                    if (stdx.isSingleItemPtr(TPartials) and @typeInfo(meta.Child(TPartials)) == .array) {
                        const Array = meta.Child(TPartials);
                        return isPartialsTupleElement(meta.Child(Array));
                    } else {
                        return isPartialsTupleElement(meta.Child(TPartials));
                    }
                }

                return false;
            }
        }

        fn isPartialsTupleElement(comptime TElement: type) bool {
            comptime {
                if (stdx.isTuple(TElement)) {
                    const field_types = @typeInfo(TElement).@"struct".field_types;
                    if (field_types.len == 2 and stdx.isZigString(field_types[0])) {
                        if (field_types[1] == PartialsMap.Template) {
                            return true;
                        } else {
                            return stdx.isZigString(field_types[1]) and stdx.isZigString(PartialsMap.Template);
                        }
                    }
                }
                return false;
            }
        }

        fn isValidMap() bool {
            comptime {
                if (@typeInfo(TPartials) == .@"struct" and stdx.hasDecls(TPartials, .{ "KV", "get" })) {
                    const KV = @field(TPartials, "KV");
                    if (@typeInfo(KV) == .@"struct" and stdx.hasFields(KV, .{ "key", "value" })) {
                        const kv: KV = undefined;
                        return stdx.isZigString(@TypeOf(kv.key)) and
                            (@TypeOf(kv.value) == PartialsMap.Template or
                                (stdx.isZigString(@TypeOf(kv.value)) and stdx.isZigString(PartialsMap.Template)));
                    }
                }

                return false;
            }
        }
    };
}

test "Map single tuple" {
    const key: []const u8 = "hello";
    const value: []const u8 = "{{hello}}world";
    const data = .{ key, value };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map single tuple - comptime value" {
    const data = .{ "hello", "{{hello}}world" };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map empty tuple" {
    const data = .{};
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);
    try testing.expect(map.get("wrong") == null);
}

test "Map void" {
    const data = {};
    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);
    try testing.expect(map.get("wrong") == null);
}

test "Map multiple tuple" {
    const Tuple = struct { []const u8, []const u8 };
    const Data = struct { Tuple, Tuple };
    const data: Data = .{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map multiple tuple comptime" {
    const data = .{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map array" {
    const data = [_]struct { []const u8, []const u8 }{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map ref array" {
    const data = &[_]struct { []const u8, []const u8 }{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map slice" {
    const array = [_]struct { []const u8, []const u8 }{
        .{ "hello", "{{hello}}world" },
        .{ "hi", "{{hi}}there" },
    };
    const data = array[0..];

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}

test "Map hashmap" {
    var data = std.StringHashMap([]const u8).init(testing.allocator);
    defer data.deinit();

    try data.put("hello", "{{hello}}world");
    try data.put("hi", "{{hi}}there");

    const dummy_options = RenderOptions{ .string = .{} };
    const DummyMap = PartialsMapType(@TypeOf(data), dummy_options);
    var map = DummyMap.init(testing.allocator, data);

    const hello = map.get("hello");
    try testing.expect(hello != null);
    try testing.expectEqualStrings("{{hello}}world", hello.?);

    const hi = map.get("hi");
    try testing.expect(hi != null);
    try testing.expectEqualStrings("{{hi}}there", hi.?);

    try testing.expect(map.get("wrong") == null);
}
