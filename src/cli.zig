//! This module provides a cli interface to projavu for on-disk storing and managing of project ideas
//! [Released under GNU LGPLv3]
//!
const std = @import("std");
const projavu = @import("lib.zig");
const argtic = @import("zig-argtic");
const c = @cImport({
    @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("table.h");
    @cInclude("levenshtein.h");
});
const Allocator = std.mem.Allocator;
const stdout = std.io.getStdOut().writer();

// The main function wraps this function for error handling purposes
fn run() CliError!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit()); // assert for memory leaks (only in debug mode)
    const allocator = gpa.allocator();

    // needs to be in this scope to prevent segmentation fault, because function parseArguments returns type that reference its data
    const argument_vector = std.process.argsAlloc(allocator) catch return error.RetrieveArguments;
    defer allocator.free(argument_vector);

    const arguments = try parseArguments(allocator, argument_vector);
    defer arguments.deinit();

    var root = try getIdeabookDir(allocator, arguments);
    defer root.close();

    const ideabook = projavu.IdeaBook{
        .allocator = allocator,
        .root = root,
        .table_basename = "table.csv",
    };

    ideabook.initializeTable() catch return error.InitializeLookupTable;

    // if return looks better than a cluttered and excessively long if-elif-else conditional
    if (arguments.isArgument("help")) return argtic.generateHelpMessage(arguments.tokenizer.specification) catch return error.HelpMessage;
    if (arguments.isArgument("version")) return stdout.writeAll("0.1.0\n") catch {};
    if (arguments.isArgument("tag")) return cliTagIdea(allocator, ideabook, arguments); // needs to be before add, because of shared subcommand name
    if (arguments.isArgument("add")) return cliAddIdea(allocator, ideabook, arguments);
    if (arguments.isArgument("view")) return cliViewIdea(allocator, ideabook, arguments);
    if (arguments.isArgument("edit")) return cliEditIdea(allocator, ideabook, arguments);
    if (arguments.isArgument("rename")) return cliRenameIdea(allocator, ideabook, arguments);
    if (arguments.isArgument("progress")) return cliUpdateIdeaProgress(ideabook, arguments);
    if (arguments.isArgument("delete")) return cliDeleteIdea(allocator, ideabook, arguments);
    if (arguments.isArgument("purge")) return cliPurgeInvalidReferences(ideabook);

    try cliFilterIdeas(allocator, ideabook, arguments);
}

// Parse the user arguments using the predefined specification
fn parseArguments(allocator: Allocator, argument_vector: []const []const u8) CliError!argtic.ArgumentProcessor {
    const flag_help = argtic.Flag{
        .name = "help",
        .short = 'h',
        .abort = true,
        .help = "Print this help and exit",
    };

    const specification = argtic.ArgumentSpecification{
        .name = "projavu",
        .short_description = "projavu - on-disk storing and managing of project ideas",
        .flags = &[_]argtic.Flag{
            flag_help,
            .{ .name = "version", .help = "Print the program's version and exit" },
            .{ .name = "target-path", .help = "Override the default ideabook location", .value = true },
            .{ .name = "filter-tag", .short = 't', .help = "Filter for a specific tag", .value = true },
            .{ .name = "filter-progress", .short = 'p', .help = "Filter for a specific progress", .value = true },
            .{ .name = "filter-id", .short = 'i', .help = "Filter for a specific id", .value = true },
        },
        .extra_positionals = argtic.Positional{
            .name = "filter",
            .help = "Filter all ideas for a specific name",
        },
        .subcommands = &[_]argtic.ArgumentSpecification{
            .{
                .name = "add",
                .short_description = "Stash an idea to the ideabook",
                .flags = &[_]argtic.Flag{flag_help},
                .extra_positionals = argtic.Positional{ .name = "title" },
            },
            .{
                .name = "view",
                .short_description = "Print an existing idea",
                .flags = &[_]argtic.Flag{flag_help},
                .positionals = &[_]argtic.Positional{
                    .{ .name = "id" },
                },
            },
            .{
                .name = "delete",
                .short_description = "Delete an idea's reference, invalidating it",
                .flags = &[_]argtic.Flag{
                    flag_help,
                    .{ .name = "no-prompt", .help = "Do not ask for interactive confirmation" },
                },
                .positionals = &[_]argtic.Positional{
                    .{ .name = "id" },
                },
            },
            .{
                .name = "edit",
                .short_description = "Edit an existing idea",
                .flags = &[_]argtic.Flag{flag_help},
                .positionals = &[_]argtic.Positional{
                    .{ .name = "id" },
                },
            },
            .{
                .name = "rename",
                .short_description = "Change the title of an idea",
                .flags = &[_]argtic.Flag{flag_help},
                .positionals = &[_]argtic.Positional{
                    .{ .name = "id" },
                },
                .extra_positionals = argtic.Positional{ .name = "new-title" },
            },
            .{
                .name = "progress",
                .short_description = "Update the progress status of an idea",
                .long_description = 
                \\Options are:
                \\  pending - This stage represents an idea that is being brainstormed or considered, but not acted upon
                \\  nigh - This stage represents an idea that is being considered for implementation in the near future
                \\  current - This stage represents an idea that is currently being implemented
                \\  maintain - This stage represents an idea that has been implemented and is now being managed, maintained, and possibly improved
                \\  archived - This stage represents an idea that is no longer being maintained or acted upon
                \\  defer - This stage represents an idea that has been intentionally delayed or postponed, possibly without a specific time frame or deadline
                ,
                .flags = &[_]argtic.Flag{flag_help},
                .positionals = &[_]argtic.Positional{
                    .{ .name = "id" },
                    .{ .name = "new-progress" },
                },
            },
            .{
                .name = "tag",
                .short_description = "Append to or remove tags from an idea",
                .flags = &[_]argtic.Flag{flag_help},
                .subcommands = &[_]argtic.ArgumentSpecification{
                    .{
                        .name = "add",
                        .positionals = &[_]argtic.Positional{.{ .name = "id" }},
                        .extra_positionals = argtic.Positional{ .name = "tags", .help = "The tags to append" },
                    },
                    .{
                        .name = "remove",
                        .positionals = &[_]argtic.Positional{.{ .name = "id" }},
                        .extra_positionals = argtic.Positional{ .name = "tags", .help = "The tags to remove" },
                    },
                },
            },
            .{
                .name = "purge",
                .short_description = "Delete all on-disk content that is not referenced anymore",
                .flags = &[_]argtic.Flag{flag_help},
            },
        },
    };

    const arguments = argtic.ArgumentProcessor.parse(allocator, specification, argument_vector[1..]) catch |tokenization_error| {
        argtic.defaultErrorHandler(tokenization_error) catch {};
        std.os.exit(22); // EINVAL
    };

    return arguments;
}

// Return the idea to the ideabook overridden via the flag target-path or calculated from the XDG_DATA_HOME environment variable
fn getIdeabookDir(allocator: Allocator, arguments: argtic.ArgumentProcessor) CliError!std.fs.Dir {
    const xdg_data_home_path = std.os.getenv("XDG_DATA_HOME") orelse return error.MissingEnvironmentVariableXDGDataHome;
    const default_root_path = try std.fs.path.join(allocator, &[_][]const u8{ xdg_data_home_path, "projavu" });
    defer allocator.free(default_root_path);
    const root_path = arguments.getArgument("target-path") orelse default_root_path;

    std.log.debug("using '{s}' as the root path", .{root_path});

    std.fs.makeDirAbsolute(root_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.MkdirIdeaBook,
    };

    return std.fs.openDirAbsolute(root_path, .{}) catch return error.OpenDirIdeaBook;
}

// Update the tags of an idea
fn cliTagIdea(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const tags_to_update = try arguments.getExtraPositionals(allocator);
    defer allocator.free(tags_to_update);
    const idea = try getIdeaFromArguments(allocator, ideabook, arguments);
    defer idea.deinit();

    var tags = std.ArrayList([]const u8).init(allocator);
    defer tags.deinit();
    try tags.appendSlice(idea.tags);

    blk_tag_update: for (tags_to_update) |tag_to_add| {
        if (arguments.isArgument("add")) {
            for (idea.tags) |tag| if (std.mem.eql(u8, tag, tag_to_add)) continue :blk_tag_update;
            try tags.append(tag_to_add);
        } else if (arguments.isArgument("remove")) {
            var offset: usize = 0;
            for (idea.tags) |tag, index| if (std.mem.eql(u8, tag, tag_to_add)) {
                _ = tags.orderedRemove(index - offset);
                offset += 1;
            };
        }
    }

    ideabook.editIdeaTags(idea.id, tags.items) catch return error.UpdateIdeaTags;

    stdout.writeAll("The tags were updated: ") catch {};
    for (tags.items) |tag, index| {
        if (index != 0) stdout.writeAll(", ") catch {};
        stdout.writeAll(tag) catch {};
    }
    stdout.writeAll("\n") catch {};
}

// Convenience function to read the argument id and fetch the idea accordingly
fn getIdeaFromArguments(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!projavu.Idea {
    const id = std.fmt.parseInt(usize, arguments.getArgument("id").?, 0) catch return error.ParseID;
    const idea = ideabook.readIdea(allocator, id) catch |err| switch (err) {
        error.InvalidID => return error.InvalidID,
        else => return error.ReadIdea,
    };

    return idea;
}

// Stash an idea to the ideabook
fn cliAddIdea(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const title_split_by_space = try arguments.getExtraPositionals(allocator);
    defer allocator.free(title_split_by_space);
    const title = try std.mem.join(allocator, " ", title_split_by_space);
    defer allocator.free(title);

    if (title.len == 0) return error.MissingArgumentTitle;

    const content = try textEditor(allocator, "idea content") orelse return error.NoIdeaContentProvided;
    defer allocator.free(content);
    errdefer std.log.warn("The following content could not be added, thus it is printed to stdout for recovery: {s}", .{content});

    const id = ideabook.addIdea(.{
        .title = title,
        .content = content,
        .progress = projavu.IdeaProgress.pending,
        .tags = &.{},
    }) catch return error.StashIdea;

    stdout.print("The idea has been added under the id: {d}\n", .{id}) catch {};
}

// Open a text editor for user input
fn textEditor(allocator: Allocator, placeholder_text: []const u8) CliError!?[]const u8 {
    var temporary_dir = std.testing.tmpDir(.{});

    const temporary_file_basename = "tmp";

    temporary_dir.dir.writeFile(temporary_file_basename, placeholder_text) catch return error.TmpFileCreate;

    const temporary_file_path = temporary_dir.dir.realpathAlloc(allocator, temporary_file_basename) catch return error.TmpFileCreate;
    defer allocator.free(temporary_file_path);
    errdefer std.log.warn("the file may be manually recovered: {s}\n", .{temporary_file_path});

    const editor_path = std.os.getenv("EDITOR") orelse return error.MissingEnvironmentVariableEDITOR;
    var process = std.ChildProcess.init(&.{ editor_path, temporary_file_path }, allocator);
    switch (process.spawnAndWait() catch return error.OpenEditor) {
        .Exited => |*signal| if (signal.* != 0) return error.OpenEditor,
        else => return error.OpenEditor,
    }

    const temporary_file = temporary_dir.dir.openFile(temporary_file_basename, .{}) catch return error.TmpFileRead;
    const end_pos = temporary_file.getEndPos() catch return error.TmpFileRead;
    const content = temporary_file.readToEndAlloc(allocator, end_pos) catch return error.TmpFileRead;

    temporary_dir.cleanup();

    if (std.mem.eql(u8, content, placeholder_text)) {
        allocator.free(content);
        return null;
    }

    return content;
}

// Print the content of an idea
fn cliViewIdea(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const idea = try getIdeaFromArguments(allocator, ideabook, arguments);
    defer idea.deinit();

    stdout.writeAll(idea.content) catch {};
}

// Edit the content of an idea
fn cliEditIdea(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const idea = try getIdeaFromArguments(allocator, ideabook, arguments);
    defer idea.deinit();
    const content = try textEditor(allocator, idea.content) orelse return error.NoIdeaContentProvided;
    defer allocator.free(content);
    errdefer std.log.warn("The following content could not be added, thus it is printed to stdout for recovery: {s}", .{content});

    ideabook.editIdeaContent(idea.id, content) catch return error.UpdateIdeaContent;

    stdout.writeAll("The idea has been edited.\n") catch {};
}

// Edit the title of an idea
fn cliRenameIdea(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const title_split_by_space = try arguments.getExtraPositionals(allocator);
    defer allocator.free(title_split_by_space);
    const title = try std.mem.join(allocator, " ", title_split_by_space);
    defer allocator.free(title);
    const idea = try getIdeaFromArguments(allocator, ideabook, arguments);
    defer idea.deinit();

    if (title.len == 0) return error.MissingArgumentTitle;

    ideabook.editIdeaTitle(idea.id, title) catch return error.UpdateIdeaTitle;

    stdout.print("The idea has been renamed: \"{s}\" -> \"{s}\"\n", .{ idea.title, title }) catch {};
}

// Update the progress of an idea
fn cliUpdateIdeaProgress(ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const id = std.fmt.parseInt(usize, arguments.getArgument("id").?, 0) catch return error.ParseID;
    const progress = projavu.IdeaProgress.fromString(arguments.getArgument("new-progress").?) orelse return error.ParseIdeaProgress;

    ideabook.editIdeaProgress(id, progress) catch return error.UpdateIdeaProgress;

    stdout.writeAll("The progress status was updated.\n") catch {};
}

// Delete the reference to an idea
fn cliDeleteIdea(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const idea = try getIdeaFromArguments(allocator, ideabook, arguments);
    defer idea.deinit();

    if (!arguments.isArgument("no-prompt")) {
        stdout.print("Delete \"{s}\"? (y/n) ", .{idea.title}) catch {};
        const answer = std.io.getStdIn().reader().readUntilDelimiterAlloc(allocator, '\n', 1024) catch return error.ReadStdIn;
        defer allocator.free(answer);

        if (!std.mem.eql(u8, answer, "y")) return error.AbortDeleteIdea;
    }

    ideabook.removeIdea(idea.id) catch return error.RemoveIdea;

    stdout.print("The idea with the title \"{s}\" has been delete.\n", .{idea.title}) catch {};
}

// Delete all leftover content that is not referenced anymore
fn cliPurgeInvalidReferences(ideabook: projavu.IdeaBook) CliError!void {
    std.log.warn("all unreferenced ideas will be permanently deleted in 15 seconds...", .{});
    std.time.sleep(15000000000);

    ideabook.cleanInvalidReferences() catch return error.CleanInvalidReferences;

    stdout.writeAll("All invalid references have been deleted.\n") catch {};
}

// Filter through all ideas and return a table matching the queries
// Certainly memory-inefficient, because of all the type conversions (function is not optimized)
fn cliFilterIdeas(allocator: Allocator, ideabook: projavu.IdeaBook, arguments: argtic.ArgumentProcessor) CliError!void {
    const filter_tags = try arguments.getArguments(allocator, "filter-tag");
    defer if (filter_tags) |tags| allocator.free(tags);
    const filter_progress = try arguments.getArguments(allocator, "filter-progress");
    defer if (filter_progress) |progress| allocator.free(progress);
    const extra_positionals = try arguments.getExtraPositionals(allocator);
    defer allocator.free(extra_positionals);
    const filter_title = try std.mem.joinZ(allocator, " ", extra_positionals);
    defer allocator.free(filter_title);

    const table = c.get_empty_table();
    defer c.free_table(table);

    const format_underline = "\x1b[4m";
    const format_reset = "\x1b[0m";

    c.add_cell(table, format_underline ++ "id " ++ format_reset ++ " ");
    c.add_cell(table, format_underline ++ "progress " ++ format_reset ++ " ");
    c.add_cell(table, format_underline ++ "title " ++ format_reset ++ " ");
    c.add_cell(table, format_underline ++ "tags " ++ format_reset);
    c.next_row(table);

    var idea_iterator = ideabook.iterateIdeas() catch return error.IterateIdeas;
    var ideas_count: usize = 0;
    var ideas_filtered_count: usize = 0;

    blk_iterate_ideas: while (idea_iterator.next() catch return error.ReadIdea) |idea| : (ideas_count += 1) {
        defer idea.deinit();

        // filter tags
        if (filter_tags) |search_tags| blk_tags: for (search_tags) |search_tag| {
            var match = false;

            for (idea.tags) |tag| {
                if (std.mem.eql(u8, search_tag, tag)) {
                    match = true;
                    break :blk_tags;
                }
            }

            if (!match) continue :blk_iterate_ideas;
        };

        // filter progress
        if (filter_progress) |search_progress| for (search_progress) |progress| {
            if (idea.progress != projavu.IdeaProgress.fromString(progress) orelse return error.ParseIdeaProgress) {
                continue :blk_iterate_ideas;
            }
        };

        // filter id
        if (arguments.getArgument("filter-id")) |filter_id| {
            const id_as_string = try std.fmt.allocPrint(allocator, "{d}", .{idea.id});
            defer allocator.free(id_as_string);

            if (!std.mem.eql(u8, id_as_string, filter_id)) continue :blk_iterate_ideas;
        }

        // filter title
        if (filter_title.len != 0) {
            var match = false;

            var title_split_by_space = std.mem.split(u8, idea.title, " ");
            while (title_split_by_space.next()) |word| {
                if (word.len <= 2) continue;

                const word_zeroterm = try allocator.dupeZ(u8, word);
                defer allocator.free(word_zeroterm);

                for (extra_positionals) |extra_positional| {
                    if (extra_positional.len <= 2) continue;

                    const filter_argument_zeroterm = try allocator.dupeZ(u8, extra_positional);
                    defer allocator.free(filter_argument_zeroterm);

                    if (c.levenshtein(filter_argument_zeroterm.ptr, word_zeroterm.ptr) <= 2) match = true;
                }
            }

            if (!match) continue :blk_iterate_ideas;
        }

        const title = try allocator.dupeZ(u8, idea.title);
        defer allocator.free(title);
        const progress = try colorFormat(allocator, idea.progress.toString());
        defer allocator.free(progress);

        var tags_formated = try allocator.dupe([]const u8, idea.tags);
        defer allocator.free(tags_formated);
        defer for (tags_formated) |tag| allocator.free(tag);
        for (tags_formated) |*tag| tag.* = try colorFormat(allocator, tag.*);
        const tags = try std.mem.joinZ(allocator, ", ", tags_formated);
        defer allocator.free(tags);

        c.add_cell_fmt(table, "%d  ", idea.id);
        c.add_cell_fmt(table, "%s  ", progress.ptr);
        c.add_cell_fmt(table, "%s ", title.ptr);
        c.add_cell_fmt(table, "%s  ", tags.ptr);
        c.next_row(table);

        ideas_filtered_count += 1;
    }

    c.make_boxed(table, c.BORDER_NONE);
    c.print_table(table);

    stdout.print("\n{d} ideas, filtered {d} ideas\n", .{ ideas_count, ideas_filtered_count }) catch {};
}

// Wrap the input into Generate ANSI Escape Color Sequences, colorizing the input based on the md5 hash of the input, calculated
fn colorFormat(allocator: Allocator, text: []const u8) ![:0]const u8 {
    var md5_hash: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(text, &md5_hash, .{});

    // "normalize" color
    const shift_R = 9; // shifting initial values for a better default progress color pallet
    const shift_G = 11;
    const shift_B = 3;
    const lighten = 140; // factor for the lightening of colors
    const max = 175; // all color values will be reduced to max

    var R: f16 = @intToFloat(f16, md5_hash[shift_R]);
    var G: f16 = @intToFloat(f16, md5_hash[shift_G]);
    var B: f16 = @intToFloat(f16, md5_hash[shift_B]);

    const total: f16 = R + G + B;

    R = (R / total) * 255;
    G = (G / total) * 255;
    B = (B / total) * 255;

    R = (R * lighten) / 100;
    G = (G * lighten) / 100;
    B = (B * lighten) / 100;

    R = @min(R, max);
    G = @min(G, max);
    B = @min(B, max);

    return std.fmt.allocPrintZ(
        allocator,
        "\x1b[38;2;{d};{d};{d}m{s}\x1b[0m",
        .{ @floatToInt(u8, R), @floatToInt(u8, G), @floatToInt(u8, B), text },
    );
}

// All the errors that the frontend may return
const CliError = error{
    RetrieveArguments,
    HelpMessage,
    InitializeLookupTable,
    MkdirIdeaBook,
    OpenDirIdeaBook,
    MissingEnvironmentVariableXDGDataHome,
    MissingEnvironmentVariableEDITOR,
    OpenEditor,
    TmpFileCreate,
    TmpFileRead,
    StashIdea,
    ReadIdea,
    IterateIdeas,
    UpdateIdeaTitle,
    UpdateIdeaContent,
    UpdateIdeaProgress,
    UpdateIdeaTags,
    RemoveIdea,
    CleanInvalidReferences,
    AbortDeleteIdea,
    ReadStdIn,
    InvalidID,
    MissingArgumentTitle,
    NoIdeaContentProvided,
    ParseIdeaProgress,
    ParseID,
    OutOfMemory,
};

pub fn main() void {
    run() catch |cli_error| errorHandler(cli_error);
}

// handle the errors that the frontend may return
fn errorHandler(cli_error: CliError) void {
    @setCold(true);

    // wrapping the switch as an argument for std.log requires frontend_error to be comptime, so thus code duplication
    switch (cli_error) {
        error.RetrieveArguments => std.log.err("could not retrieve the argument vector", .{}),
        error.HelpMessage => std.log.err("could not print the help message", .{}),
        error.InitializeLookupTable => std.log.err("could not initialize the ideabook", .{}),
        error.MkdirIdeaBook => std.log.err("could not create the root directory for the ideabook", .{}),
        error.OpenDirIdeaBook => std.log.err("could not open the root directory of the ideabook", .{}),
        error.MissingEnvironmentVariableXDGDataHome => std.log.err("the environment variable $XDG_DATA_HOME is required, but not provided", .{}),
        error.MissingEnvironmentVariableEDITOR => std.log.err("the environment variable $EDITOR is required, but not provided", .{}),
        error.OpenEditor => std.log.err("could not spawn an editor for editing an idea", .{}),
        error.TmpFileCreate => std.log.err("could not create a new temporary file", .{}),
        error.TmpFileRead => std.log.err("could not read the content of the temporary file", .{}),
        error.StashIdea => std.log.err("could not store the idea", .{}),
        error.ReadIdea => std.log.err("could not read an idea", .{}),
        error.IterateIdeas => std.log.err("could not iterate through all ideas", .{}),
        error.UpdateIdeaTitle => std.log.err("could not update the title", .{}),
        error.UpdateIdeaContent => std.log.err("could not update the content", .{}),
        error.UpdateIdeaProgress => std.log.err("could not update the progress", .{}),
        error.UpdateIdeaTags => std.log.err("could not update the tags", .{}),
        error.RemoveIdea => std.log.err("could not remove the idea", .{}),
        error.CleanInvalidReferences => std.log.err("could not cleanup invalid references", .{}),
        error.AbortDeleteIdea => std.log.err("no idea was deleted -> the deletion was aborted", .{}),
        error.ReadStdIn => std.log.err("could not read stdin", .{}),
        error.InvalidID => std.log.err("demanded an invalid idea", .{}),
        error.MissingArgumentTitle => std.log.err("no title was provided", .{}),
        error.NoIdeaContentProvided => std.log.err("no content was provided", .{}),
        error.ParseIdeaProgress => std.log.err("the requested progress does not exist (all progress stages listed in help)", .{}),
        error.ParseID => std.log.err("could not parse the requested id", .{}),
        error.OutOfMemory => std.log.err("there is not enough memory to run this application", .{}),
    }

    std.os.exit(1);
}
