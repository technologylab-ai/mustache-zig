# Mustache for Zig 0.16.0

A pure Zig, MIT-licensed Mustache library with cached templates and standard
`std.Io.Writer` output. This fork adds **bounded cached rendering** for
[Baz](https://github.com/technologylab-ai/baz): explicit work/depth limits,
parser recursion guards, and independent official-core and Zap compatibility tests.

Based on [diogok's Zig 0.16 port](https://github.com/diogok/mustache-zig/tree/eb023612e85774861e6a9be18e674a497a340f0f)
of [batiati/mustache-zig](https://github.com/batiati/mustache-zig).
Thank you to the original authors and contributors. Their [MIT license](LICENSE.txt)
and source attribution remain intact.

## Parse once, render into your writer

Import the `mustache` module from this package. Use **exact Zig 0.16.0**.

```zig
const std = @import("std");
const mustache = @import("mustache");

pub fn main(init: std.process.Init) !void {
    const parsed = try mustache.parseText(init.gpa, "Hello {{name}}!", .{}, .{
        .copy_strings = true,
        .features = .{ .lambdas = .disabled },
    });
    const template = switch (parsed) {
        .success => |value| value,
        .parse_error => return error.InvalidTemplate,
    };
    defer template.deinit(init.gpa);

    var output: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try mustache.renderBounded(template, .{ .name = "Zig" }, &writer, .{});
    std.debug.assert(std.mem.eql(u8, writer.buffered(), "Hello Zig!"));
}
```

For explicit cached partials:

```zig
try mustache.renderPartialsBounded(template, partials, data, writer, .{
    .max_depth = 64,
    .max_work = 1_000_000,
});
```

`partials` can be a tuple/slice of name/template pairs, or a standard
`std.StringHashMap(Template)` / `std.StringHashMapUnmanaged(Template)`. Partials are parsed independently with their
own starting delimiters. Typed Zig arrays, slices, structs, optionals and
numbers work directly. For runtime-shaped data, use `mustache.Value`; convert
`std.json.Value` explicitly as shown in [the specification runner](tests/spec.zig).
Missing values render empty.

## Bounded API contract

- Parsing takes a caller allocator. Use a fixed startup allocator and a source
  size limit when a hard startup memory bound is required. Parser section and
  dotted-path recursion have a hard depth limit of 128.
- The cached bounded renderer takes **no allocator**, performs no file I/O, and
  does not mutate templates. Share immutable templates across calls; each call
  needs exclusive writer storage. Keep borrowed template strings and data alive.
- A shared budget charges nodes, iterations (including empty sections), context
  and partial lookup, and source/output bytes. `max_work` is an implementation
  budget, not a time measurement. Runtime depth is at most 128.
- A limit returns `WorkLimitExceeded` or `DepthLimitExceeded`. A failed output
  writer returns `WriteFailed`. An error can leave a prefix in the destination;
  discard it before publishing if partial output is unacceptable.
- Parse with lambdas disabled. Lambda-enabled templates, inheritance/blocks,
  and dynamic partial names are outside the bounded API and return an error.
- Core Mustache interpolation escapes HTML. Raw interpolation bypasses it;
  neither operation validates application-specific URLs or script contexts.

The inherited `render`, `allocRender`, `renderText`, file-loading, lambda and
comptime APIs remain available for existing consumers. **They do not acquire
these cached-render bounds.** Optional FFI/sample projects are inherited material,
not part of this fork's bounded-runtime qualification. Baz uses only the pure
Zig cached path and adds aggregate template storage/source/element limits.

## Verification

```sh
zig build verify -Doptimize=Debug -j2
zig build verify -Doptimize=ReleaseSafe -j2
zig build check -Dtarget=x86_64-windows -Doptimize=ReleaseSafe -j2
```

`verify` runs the inherited runtime/unit suite, focused budget/parser regressions,
**all 136 official core cases** with normal and exact-capacity output, and four
original Zap compatibility/allocator tests. The core runner skips no cases.
Upstream comptime tests remain disabled by default and report their skips
separately; optional Mustache specification modules are explicitly excluded.
Fixture revisions, hashes, counts and MIT licenses are in [tests/spec](tests/spec/README.md).

CI verifies Debug and ReleaseSafe natively on Linux, macOS and Windows using
checksum-verified Zig 0.16.0. Cross-compilation is compilation evidence only.
