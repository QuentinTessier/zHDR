# zHDR

Import .hdr file in zig

For large files, you should prioritize loading the all file in memory and using `zHDR.parseFromMemory` has it is much faster than other options.
`zHDR.parseFromFile` can take up to 2 minutes to parse a 8k image.

```zig
const allocator = some_allocator;

// For small file
var img = zHDR.parseFromFilePath(allocator, "./file.hdr");
defer zHDR.releaseImage(allocator, &img);

// For larger files
var file = try std.fs.cwd().openFile("./file.hdr", .{});
defer file.close();

const endPos = try file.getEndPos();
const content = try file.readToEndAlloc(allocator, endPos);
defer allocator.free(content);

var img = zHDR.parseFromMemory(allocator, content);
defer zHDR.releaseImage(allocator, &img);

```
