# Official Mustache core fixtures

These files come from [mustache/spec](https://github.com/mustache/spec/tree/e8ec001db7f594521e773c34866aca2b5d6b0037).
The pinned revision is `e8ec001db7f594521e773c34866aca2b5d6b0037`.
The JSON files and [MIT license](LICENSE) are unchanged.
[provenance.json](provenance.json) records their hashes and case counts.

The runner executes all 136 cases across six core suites.
The runner checks each case with bounded output and exact output capacity.
The runner retains parsed JSON and template sources until rendering completes.
Failures identify both the suite and case.

The runner uses the cached, bounded rendering API with lambdas disabled.
Setup converts parsed JSON into the renderer's borrowed `Value` tree.
The runner preserves JSON numbers as text because `Value` has no numeric variant.
Separate typed Zig fixtures verify native integer interpolation.
The [Zap fixture license](LICENSE-ZAP) applies to adapted data in `../zap.zig`.

| Suite | Cases |
| --- | ---: |
| Comments | 12 |
| Delimiters | 14 |
| Interpolation | 42 |
| Inverted sections | 22 |
| Partials | 12 |
| Sections | 34 |

The upstream `~lambdas`, `~inheritance`, and `~dynamic-names` modules are optional.
These fixtures exclude those modules and make no support claim for them.
No core cases are skipped.
