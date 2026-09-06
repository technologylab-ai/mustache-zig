const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const mustache = @import("../mustache.zig");
const TemplateOptions = mustache.options.TemplateOptions;

const Element = mustache.Element;

const ref_counter = @import("ref_counter.zig");

const parsing = @import("parsing.zig");
const Delimiters = parsing.Delimiters;
const IndexBookmark = parsing.IndexBookmark;

pub fn NodeType(comptime options: TemplateOptions) type {
    const RefCounter = ref_counter.RefCounterType(options);
    const has_trimming = options.features.preserve_line_breaks_and_indentation;
    const allow_lambdas = options.features.lambdas == .enabled;

    return struct {
        const Node = @This();

        pub const List = std.ArrayList(Node);
        pub const TextPart = parsing.TextPartType(options);

        index: u32 = 0,
        identifier: ?[]const u8,
        text_part: TextPart,

        children_count: u32 = 0,
        delimiters: ?Delimiters = null,

        inner_text: if (allow_lambdas) struct {
            content: ?[]const u8 = null,
            ref_counter: RefCounter = .{},
            bookmark: ?IndexBookmark = null,
        } else void = if (allow_lambdas) .{} else {},

        pub fn unRef(self: *Node, allocator: Allocator) void {
            if (comptime options.isRefCounted()) {
                self.text_part.unRef(allocator);
                if (allow_lambdas) {
                    self.inner_text.ref_counter.unRef(allocator);
                }
            }
        }

        pub fn trimStandAlone(self: *Node, list: *List) void {
            if (comptime !has_trimming) return;

            var text_part = &self.text_part;
            if (text_part.part_type == .static_text) {
                switch (text_part.trimming.left) {
                    .preserve_whitespaces => {},
                    .trimmed => assert(false),
                    .allow_trimming => {
                        const can_trim = trimPreviousNodesRight(list, self.index);
                        if (can_trim) {
                            text_part.trimLeft();
                        } else {
                            text_part.trimming.left = .preserve_whitespaces;
                        }
                    },
                }
            }
        }

        pub fn trimLast(self: *Node, allocator: Allocator, nodes: *List) void {
            if (comptime !has_trimming) return;
            if (nodes.items.len == 0) return;

            var text_part = &self.text_part;
            if (text_part.part_type == .static_text) {
                if (!text_part.is_stand_alone) {
                    var index = nodes.items.len - 1;
                    if (self.index == index) return;

                    assert(self.index < index);

                    while (self.index < index) : (index -= 1) {
                        const node = &nodes.items[index];

                        if (!node.text_part.is_stand_alone) {
                            return;
                        }
                    }
                }

                var maybe_indentation = text_part.trimRight();
                if (maybe_indentation) |*indentation| {
                    if (self.index == nodes.items.len - 1) {
                        // The last tag can't produce any meaningful indentation, so we discard it
                        indentation.ref_counter.unRef(allocator);
                    } else {
                        var next_node = &nodes.items[self.index + 1];
                        next_node.text_part.indentation = indentation.*;
                    }
                }
            }
        }

        pub fn getIndentation(self: *const Node) ?[]const u8 {
            return if (comptime has_trimming)
                switch (self.text_part.part_type) {
                    .partial,
                    .parent,
                    => if (self.text_part.indentation) |indentation| indentation.slice else null,
                    else => null,
                }
            else
                null;
        }

        pub fn getInnerText(self: *const Node) ?[]const u8 {
            if (comptime allow_lambdas) {
                if (self.inner_text.content) |node_inner_text| {
                    return node_inner_text;
                }
            }

            return null;
        }

        fn trimPreviousNodesRight(nodes: *List, index: u32) bool {
            if (comptime !has_trimming) return false;

            // Find the first decisive predecessor without growing the stack.
            var cursor: usize = index;
            var can_trim = true;
            while (cursor > 0) {
                cursor -= 1;
                const text_part = &nodes.items[cursor].text_part;
                if (text_part.part_type == .static_text) {
                    switch (text_part.trimming.right) {
                        .allow_trimming => |trimming| if (trimming.stand_alone) {
                            break;
                        },
                        .trimmed => break,
                        .preserve_whitespaces => {
                            can_trim = false;
                            break;
                        },
                    }
                } else if (!text_part.is_stand_alone) {
                    can_trim = false;
                    break;
                }
            }

            // Apply the same decisions in predecessor-to-successor order.
            while (cursor < index) : (cursor += 1) {
                const text_part = &nodes.items[cursor].text_part;
                if (text_part.part_type != .static_text or text_part.trimming.right != .allow_trimming) continue;
                if (can_trim) {
                    if (text_part.trimRight()) |indentation| {
                        nodes.items[cursor + 1].text_part.indentation = indentation;
                    }
                } else {
                    text_part.trimming.right = .preserve_whitespaces;
                }
            }
            return can_trim;
        }
    };
}
