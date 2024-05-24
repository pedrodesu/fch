const std = @import("std");
const c = @cImport({
    @cInclude("sys/statvfs.h");
    @cInclude("sys/sysinfo.h");
});

fn name(allocator: std.mem.Allocator) ![]const u8 {
    const os_file = try std.fs.openFileAbsolute("/etc/os-release", .{});
    defer os_file.close();

    var kv = std.StringHashMap([]const u8).init(allocator);
    defer kv.deinit();

    const reader = @constCast(&std.io.bufferedReader(os_file.reader())).reader();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (try reader.readUntilDelimiterOrEofAlloc(arena.allocator(), '\n', 4096)) |line| {
        if (line.len == 0)
            continue;
        var property_it = std.mem.tokenizeScalar(u8, line, '=');
        const k = property_it.next().?;
        const v = property_it.next().?;
        try kv.put(k, v);
    }

    const value = kv.get("PRETTY_NAME").?;
    return try allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn memory(allocator: std.mem.Allocator) !std.meta.Tuple(&.{ u64, u64 }) {
    const mem_file = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer mem_file.close();

    var kv = std.StringHashMap([]const u8).init(allocator);
    defer kv.deinit();

    const reader = @constCast(&std.io.bufferedReader(mem_file.reader())).reader();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (try reader.readUntilDelimiterOrEofAlloc(arena.allocator(), '\n', 4096)) |line| {
        if (line.len == 0)
            continue;
        var property_it = std.mem.tokenizeAny(u8, line, ": ");
        const k = property_it.next().?;
        const v = property_it.next().?;
        try kv.put(k, v);

        if (kv.contains("MemAvailable") and kv.contains("MemTotal"))
            break;
    }

    return .{ try std.fmt.parseInt(u64, kv.get("MemAvailable").?, 10) / 1024, try std.fmt.parseInt(u64, kv.get("MemTotal").?, 10) / 1024 };
}

fn space() !std.meta.Tuple(&.{ f64, f64 }) {
    var stats = c.struct_statvfs{};

    const res = std.posix.errno(c.statvfs("/", &stats));

    if (res != .SUCCESS)
        return std.posix.unexpectedErrno(res);

    const total_disk = @as(f64, @floatFromInt(stats.f_blocks * stats.f_bsize)) / 1_000_000_000;
    const rem_disk = @as(f64, @floatFromInt(stats.f_bavail * stats.f_bsize)) / 1_000_000_000;

    return .{ rem_disk, total_disk };
}

fn uptime() u64 {
    var info = c.struct_sysinfo{};

    _ = c.sysinfo(&info);
    return @as(u64, @intCast(info.uptime));
}

fn cpu(allocator: std.mem.Allocator) !std.meta.Tuple(&.{ []u8, []u8 }) {
    const cpu_file = try std.fs.openFileAbsolute("/proc/cpuinfo", .{});
    defer cpu_file.close();

    var kv = std.StringHashMap([]const u8).init(allocator);
    defer kv.deinit();

    const reader = @constCast(&std.io.bufferedReader(cpu_file.reader())).reader();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (try reader.readUntilDelimiterOrEofAlloc(arena.allocator(), '\n', 4096)) |line| {
        var property_it = std.mem.splitScalar(u8, line, ':');
        const k = std.mem.trimRight(u8, property_it.next().?, &std.ascii.whitespace);
        const v = std.mem.trimLeft(u8, property_it.next() orelse continue, &std.ascii.whitespace);
        try kv.put(k, v);

        if (kv.contains("model name") and kv.contains("cpu cores"))
            break;
    }

    return .{ try allocator.dupe(u8, kv.get("model name").?), try allocator.dupe(u8, kv.get("cpu cores").?) };
}

fn gpu(allocator: std.mem.Allocator) !?[]const u8 {
    const lspci = try std.ChildProcess.run(.{ .allocator = allocator, .argv = &[_][]const u8{"lspci"} });
    defer allocator.free(lspci.stderr);
    defer allocator.free(lspci.stdout);

    var it = std.mem.splitScalar(u8, lspci.stdout, '\n');
    while (it.next()) |l| {
        if (std.mem.count(u8, l, "VGA") == 1) {
            const left_bound = std.mem.indexOfScalarPos(u8, l, 8, ':').? + 2;
            const right_bound = std.mem.lastIndexOfScalar(u8, l, '(').? - 1;
            return try allocator.dupe(u8, l[left_bound..right_bound]);
        }
    }

    return null;
}

const ANSI_TITLE = "\x1b[1;38;2;112;103;207m";
const ANSI_FIELD = "\x1b[0;38;2;141;133;217m";
const ANSI_GRAY = "\x1b[0;38;2;85;85;85m";
const ANSI_ORANGE = "\x1b[0;38;2;255;127;0m";
const ANSI_RESET = "\x1b[0m";

pub fn main() !void {
    const user = std.posix.getenv("USER").?;
    var host_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = try std.posix.gethostname(&host_buffer);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const head = try std.fmt.allocPrint(gpa.allocator(), ANSI_TITLE ++ "{s}" ++ ANSI_RESET ++ "@" ++ ANSI_TITLE ++ "{s}" ++ ANSI_RESET, .{ user, host });
    defer gpa.allocator().free(head);

    const os = try name(gpa.allocator());
    defer gpa.allocator().free(os);

    const kernel = std.posix.uname().release;
    const mem = try memory(gpa.allocator());
    const disk = try space();

    const cpu_info = try cpu(gpa.allocator());
    defer gpa.allocator().free(cpu_info.@"0");
    defer gpa.allocator().free(cpu_info.@"1");

    const gpu_model = try gpu(gpa.allocator()) orelse "none";
    defer gpa.allocator().free(gpu_model);

    const uptime_raw = uptime();
    const uptime_format = try if (uptime_raw < 60)
        std.fmt.allocPrint(gpa.allocator(), "{}s", .{uptime_raw})
    else if (uptime_raw < 60 * 60)
        std.fmt.allocPrint(gpa.allocator(), "{}m {}s", .{ uptime_raw / 60, uptime_raw % 60 })
    else
        std.fmt.allocPrint(gpa.allocator(), "{}h {}m {}s", .{ uptime_raw / 60 / 60, uptime_raw / 60 % 60, uptime_raw % 60 });
    defer gpa.allocator().free(uptime_format);

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print(
        \\
        \\                  {s}
        \\       
    ++ ANSI_GRAY ++ "___" ++ ANSI_RESET ++
        \\        
    ++ ANSI_FIELD ++ "os" ++ ANSI_RESET ++
        \\          {s}
        \\      
    ++ ANSI_GRAY ++ "(" ++ ANSI_RESET ++
        \\.· 
    ++ ANSI_GRAY ++ "|" ++ ANSI_RESET ++
        \\       
    ++ ANSI_FIELD ++ "kernel" ++ ANSI_RESET ++
        \\      {s}
        \\      
    ++ ANSI_GRAY ++ "(" ++ ANSI_RESET ++ ANSI_ORANGE ++ "<>" ++ ANSI_RESET ++
        \\ 
    ++ ANSI_GRAY ++ "|" ++ ANSI_RESET ++
        \\       
    ++ ANSI_FIELD ++ "memory" ++ ANSI_RESET ++
        \\      {}M / {}M
        \\     
    ++ ANSI_GRAY ++ "/" ++ ANSI_RESET ++
        \\ __  
    ++ ANSI_GRAY ++ "\\" ++ ANSI_RESET ++
        \\      
    ++ ANSI_FIELD ++ "disk" ++ ANSI_RESET ++
        \\        {d:.1}G / {d:.1}G
        \\    
    ++ ANSI_GRAY ++ "(" ++ ANSI_RESET ++
        \\ /  \ 
    ++ ANSI_GRAY ++ "/|" ++ ANSI_RESET ++
        \\     
    ++ ANSI_FIELD ++ "cpu" ++ ANSI_RESET ++
        \\         {s} × {s}
        \\  
    ++ ANSI_ORANGE ++ "_" ++ ANSI_GRAY ++ "/\\" ++ ANSI_RESET ++
        \\ __)
    ++ ANSI_GRAY ++ "/" ++ ANSI_ORANGE ++ "_" ++ ANSI_GRAY ++ ")" ++ ANSI_RESET ++
        \\      
    ++ ANSI_FIELD ++ "gpu" ++ ANSI_RESET ++
        \\         {s}
        \\  
    ++ ANSI_ORANGE ++ "\\/" ++
        ANSI_GRAY ++ "-____" ++
        ANSI_ORANGE ++ "\\/" ++ ANSI_RESET ++
        \\       
    ++ ANSI_FIELD ++ "uptime" ++ ANSI_RESET ++
        \\      {s}
        \\
        \\
        \\
    , .{ head, os, kernel, mem.@"0", mem.@"1", disk.@"0", disk.@"1", cpu_info.@"0", cpu_info.@"1", gpu_model, uptime_format });
    try bw.flush();
}
