# Funnel

Small library that wraps functionality of sending objects over posix pipes.

The library uses `pipe2` to allow non-blocking functionality.

## Installation

Fetch with zig.

```bash
zig fetch --save git+https://github.com/jmatth11/funnel#main
```

Add to your `build.zig`

```zig
const funnel_lib = b.dependency("funnel", .{
    .target = target,
});

lib.root_module.addImport("funnel", funnel_lib.module("funnel"));
```

## Examples

Find example usages under the `examples` folder.

Examples expect the project to have been built prior to building the example projects.

