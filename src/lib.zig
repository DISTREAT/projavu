//! This module provides structs for on-disk storing and managing of project ideas
//! [Released under GNU LGPLv3]
//!
const std = @import("std");
const csv = @import("zig-csv");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Representation of an idea
pub const Idea = struct {
    // Used for the allocation and freeing of the field values
    allocator: Allocator,
    /// The idea's ID, as stored in the lookup table
    id: usize,
    /// The idea's reference to the on-disk content
    reference: []const u8,
    /// The idea's title, as stored in the lookup table
    title: []const u8,
    /// The idea's content, as stored on-disk
    content: []const u8,
    /// The idea's progress, as stored in the lookup table
    progress: IdeaProgress,
    /// The idea's tags, as stored in the lookup table
    tags: []const []const u8,

    /// Free all used memory
    pub fn deinit(self: Idea) void {
        self.allocator.free(self.title);
        self.allocator.free(self.reference);
        self.allocator.free(self.content);
        for (self.tags) |tag| self.allocator.free(tag);
        self.allocator.free(self.tags);
    }
};

/// Representation of an idea's progress
pub const IdeaProgress = enum {
    /// This stage represents an idea that is being brainstormed or considered, but not acted upon
    pending,
    /// This stage represents an idea that is being considered for implementation in the near future
    nigh,
    /// This stage represents an idea that is currently being implemented
    current,
    /// This stage represents an idea that has been implemented and is now being managed, maintained, and possibly improved
    maintain,
    /// This stage represents an idea that is no longer being maintained or acted upon
    archived,
    /// This stage represents an idea that has been intentionally delayed or postponed, possibly without a specific time frame or deadline
    @"defer",

    const string_representation = [_][]const u8{
        "pending",
        "nigh",
        "current",
        "maintain",
        "archived",
        "defer",
    };

    /// Convert the enum value into a string representation
    pub fn toString(self: IdeaProgress) []const u8 {
        return string_representation[@enumToInt(self)];
    }

    /// Convert a string into it's enum representation, if exists
    pub fn fromString(string: []const u8) ?IdeaProgress {
        for (string_representation) |value, index| {
            if (std.mem.eql(u8, string, value)) {
                return @intToEnum(IdeaProgress, index);
            }
        }

        return null;
    }
};

/// A struct for iterating over and querying stashed ideas
const IdeaIterator = struct {
    /// The IdeaBook that initialized this instance
    parent: IdeaBook,
    /// The highest id after which it should not search for any more ids, but return null
    last_id: usize,
    /// Current index, used for iterating using the method IdeaIterator.next
    iterator_index: usize = 1,

    pub fn next(self: *IdeaIterator) IdeaBookError!?Idea {
        // recursion, because I am lazy ;)
        if (self.iterator_index > self.last_id) return null;

        const idea = self.parent.readIdea(self.parent.allocator, self.iterator_index) catch |err| switch (err) {
            error.InvalidID => {
                self.iterator_index += 1;
                return try self.next();
            },
            else => return err,
        };

        self.iterator_index += 1;

        return idea;
    }
};

/// Error returned by struct Ideabook
pub const IdeaBookError = error{
    /// Error while reading the lookup table
    ReadTable,
    /// Error while parsing the lookup table
    ParsingTable,
    /// Error while facing data that is not expected to be there
    /// Might hint at a manually-edited lookup table
    UnexpectedTable,
    /// Error while exporting or writing the lookup table
    WriteTable,
    /// Error while trying to insert values into the lookup table
    InsertTable,
    /// Error storing the ideas content on-disk
    StashContent,
    /// Error following reference and reading its requested content
    ReadContent,
    /// Error deleting an on-disk idea's content
    DeleteContent,
    /// The requested idea does not exist
    InvalidID,
    /// A tag contains a character that is illegal, in this case a white-space
    IllegalCharacterInTag,
    /// Error deleting a directory
    DeleteDirectory,
    /// Not enough memory to store additional data
    OutOfMemory,
};

/// A representation of on-disk notebooks, which contain ideas
pub const IdeaBook = struct {
    /// Allocator used for buffering purposes
    allocator: Allocator,
    /// The Dir used for stashing ideas and storing the lookup table
    root: std.fs.Dir,
    /// The name of the file used for referencing ideas alongside other information (also referred to as lookup table)
    table_basename: []const u8,

    /// Convenience method to read and parse the lookup table
    fn readTable(self: IdeaBook, allocator: Allocator) IdeaBookError!csv.Table {
        var table = csv.Table.init(allocator, csv.Settings.default());
        const stat = self.root.statFile(self.table_basename) catch return error.ReadTable;
        const content = self.root.readFileAlloc(
            table.arena_allocator.allocator(),
            self.table_basename,
            stat.size,
        ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ReadTable,
        };
        table.parse(content) catch return error.ParsingTable;
        return table;
    }

    /// Convenience method to export and write the lookup table
    fn writeTable(self: IdeaBook, table: *csv.Table) IdeaBookError!void {
        const csv_exported = table.exportCSV(self.allocator) catch return error.WriteTable;
        defer self.allocator.free(csv_exported);
        self.root.writeFile(self.table_basename, csv_exported) catch return error.WriteTable;
    }

    /// Calculate a path via the content's hash that will be used as the idea's reference
    fn pathFromContent(allocator: Allocator, content: []const u8) IdeaBookError![]const u8 {
        var hash: [32]u8 = undefined;
        Sha256.hash(content, &hash, .{});

        // TODO: replace with std.fmt.bytesToHex in the future
        var path = ArrayList(u8).init(allocator);
        const path_writer = path.writer();

        try std.fmt.fmtSliceHexLower(hash[0..1]).format(&.{}, .{}, path_writer);
        try path.appendSlice("/");
        try std.fmt.fmtSliceHexLower(hash[1..32]).format(&.{}, .{}, path_writer);

        return path.toOwnedSlice();
    }

    /// Return a slice of references to all existing on-disk ideas
    fn pathsOfContents(self: IdeaBook, allocator: Allocator) IdeaBookError![]const []const u8 {
        var references = ArrayList([]const u8).init(allocator);

        var dir = self.root.openIterableDir(".", .{}) catch return error.ReadContent;
        defer dir.close();

        // the only error that should be able to return is OutOfMemory, since only Allocator.Error is returnable and it is the only field
        var walker = dir.walk(self.allocator) catch return error.OutOfMemory;
        defer walker.deinit();

        while (walker.next() catch return error.ReadContent) |entry| {
            // check for len 2 basename, since the path is calculated from the content's hash and
            // has a static size of 62 (file name) + 2 (dir name) = 64 c
            if (entry.kind == .File and entry.basename.len == 62) {
                try references.append(try allocator.dupe(u8, entry.path));
            }
        }

        return references.toOwnedSlice();
    }

    /// Store the content of an idea on-disk inside of self.root, returning the content's reference
    fn stashContent(self: IdeaBook, allocator: Allocator, idea_content: []const u8) IdeaBookError![]const u8 {
        const path = try IdeaBook.pathFromContent(allocator, idea_content);

        self.root.makeDir(std.fs.path.dirname(path).?) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                return error.StashContent;
            },
        };

        if (self.root.access(path, .{}) == error.FileNotFound) {
            var file = self.root.createFile(path, .{}) catch return error.StashContent;
            defer file.close();
            file.writeAll(idea_content) catch return error.StashContent;
        }

        return path;
    }

    /// Follow an idea's reference and read the idea's content
    fn readContentFromReference(self: IdeaBook, allocator: Allocator, reference: []const u8) IdeaBookError![]const u8 {
        const stat = self.root.statFile(reference) catch return error.ReadContent;
        return self.root.readFileAlloc(
            allocator,
            reference,
            stat.size,
        ) catch return error.ReadContent;
    }

    /// Calculate the next unique ID that is available for use within the lookup table
    fn nextID(self: IdeaBook) IdeaBookError!usize {
        var table = try self.readTable(self.allocator);
        defer table.deinit();

        const column_index_ids = table.findColumnIndexesByKey(self.allocator, "id") catch return error.UnexpectedTable;
        defer self.allocator.free(column_index_ids);

        var ids = table.getColumnByIndex(column_index_ids[0]);
        var last_id: usize = 0;

        while (ids.next()) |id_item| {
            const id = std.fmt.parseInt(usize, id_item.value, 10) catch return error.UnexpectedTable;
            if (id > last_id) last_id = id;
        }

        return last_id + 1;
    }

    /// Push a new entry to the lookup table
    fn pushTableEntry(self: IdeaBook, idea: anytype) IdeaBookError!void {
        if (@TypeOf(idea.progress) != IdeaProgress) @compileError("Expected IdeaProgress");
        for (idea.tags) |tag| if (std.mem.count(u8, tag, " ") != 0) return error.IllegalCharacterInTag;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        var table = try self.readTable(self.allocator);
        defer table.deinit();

        const column_index_id = table.findColumnIndexesByKey(allocator, "id") catch return error.UnexpectedTable;
        const column_index_reference = table.findColumnIndexesByKey(allocator, "reference") catch return error.UnexpectedTable;
        const column_index_title = table.findColumnIndexesByKey(allocator, "title") catch return error.UnexpectedTable;
        const column_index_progress = table.findColumnIndexesByKey(allocator, "progress") catch return error.UnexpectedTable;
        const column_index_tags = table.findColumnIndexesByKey(allocator, "tags") catch return error.UnexpectedTable;

        const formated_id = try std.fmt.allocPrint(allocator, "{d}", .{idea.id});
        const formated_tags = try std.mem.join(allocator, " ", idea.tags);

        // returns OutOfMemory because it is the only possible returning type, even though more errors are listed
        const row_index = table.insertEmptyRow() catch return error.OutOfMemory;
        table.replaceValue(row_index, column_index_id[0], formated_id) catch return error.InsertTable;
        table.replaceValue(row_index, column_index_reference[0], idea.reference) catch return error.InsertTable;
        table.replaceValue(row_index, column_index_title[0], idea.title) catch return error.InsertTable;
        table.replaceValue(row_index, column_index_progress[0], idea.progress.toString()) catch return error.InsertTable;
        table.replaceValue(row_index, column_index_tags[0], formated_tags) catch return error.InsertTable;

        try self.writeTable(&table);
    }

    /// Pop the entry with the provided ID of the lookup table
    fn popTableEntry(self: IdeaBook, idea_id: usize) IdeaBookError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var table = try self.readTable(allocator);

        const formated_id = try std.fmt.allocPrint(allocator, "{d}", .{idea_id});
        const column_index = table.findColumnIndexesByKey(allocator, "id") catch return error.UnexpectedTable;
        const row_index = table.findRowIndexesByValue(allocator, column_index[0], formated_id) catch |e| switch (e) {
            error.RowNotFound => return error.InvalidID,
            else => return error.UnexpectedTable,
        };

        table.deleteRowByIndex(row_index[0]) catch return error.ParsingTable;

        try self.writeTable(&table);
    }

    /// Delete all on-disk contents that are not referenced by the lookup table
    pub fn cleanInvalidReferences(self: IdeaBook) IdeaBookError!void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var table = try self.readTable(allocator);
        const column_index = table.findColumnIndexesByKey(allocator, "reference") catch return error.UnexpectedTable;

        var recorded_refs = table.getColumnByIndex(column_index[0]);
        const stored_refs = try self.pathsOfContents(allocator);

        for (stored_refs) |stored_ref| {
            var exists_in_lookup = false;

            recorded_refs.reset();
            while (recorded_refs.next()) |recorded_ref| {
                if (std.mem.eql(u8, stored_ref, recorded_ref.value)) exists_in_lookup = true;
            }

            if (!exists_in_lookup) {
                // this code should not fail, since all references have a dirname and a basename
                const dirname = std.fs.path.dirname(stored_ref) orelse unreachable;

                self.root.deleteFile(stored_ref) catch return error.DeleteContent;
                self.root.deleteDir(dirname) catch |e| switch (e) {
                    error.DirNotEmpty => {}, // ignore, since the still includes files
                    else => return error.DeleteDirectory, // delete obsolete directory
                };
            }
        }
    }

    /// Initialize the lookup table for new IdeaBooks
    pub fn initializeTable(self: IdeaBook) IdeaBookError!void {
        var table = csv.Table.init(self.allocator, csv.Settings.default());
        defer table.deinit();

        _ = table.insertEmptyColumn("id") catch return error.InsertTable;
        _ = table.insertEmptyColumn("reference") catch return error.InsertTable;
        _ = table.insertEmptyColumn("title") catch return error.InsertTable;
        _ = table.insertEmptyColumn("progress") catch return error.InsertTable;
        _ = table.insertEmptyColumn("tags") catch return error.InsertTable;

        if (self.root.access(self.table_basename, .{}) == error.FileNotFound) {
            try self.writeTable(&table);
        }
    }

    /// Retrieve the idea with the provided ID
    pub fn readIdea(self: IdeaBook, allocator: Allocator, idea_id: usize) IdeaBookError!Idea {
        const formated_id = try std.fmt.allocPrint(self.allocator, "{d}", .{idea_id});
        defer self.allocator.free(formated_id);

        var table = try self.readTable(self.allocator);
        defer table.deinit();
        var rows = table.getAllRows();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const column_allocator = arena.allocator();

        const column_index_id = table.findColumnIndexesByKey(column_allocator, "id") catch return error.UnexpectedTable;
        const column_index_reference = table.findColumnIndexesByKey(column_allocator, "reference") catch return error.UnexpectedTable;
        const column_index_title = table.findColumnIndexesByKey(column_allocator, "title") catch return error.UnexpectedTable;
        const column_index_progress = table.findColumnIndexesByKey(column_allocator, "progress") catch return error.UnexpectedTable;
        const column_index_tags = table.findColumnIndexesByKey(column_allocator, "tags") catch return error.UnexpectedTable;

        while (true) { // row may not be *const, thus this approach
            var row = rows.next() orelse break;

            const row_value_id = (row.get(column_index_id[0]) catch return error.UnexpectedTable).value;

            if (std.mem.eql(u8, formated_id, row_value_id)) {
                const row_value_reference = (row.get(column_index_reference[0]) catch return error.UnexpectedTable).value;
                const row_value_title = (row.get(column_index_title[0]) catch return error.UnexpectedTable).value;
                const row_value_progress = (row.get(column_index_progress[0]) catch return error.UnexpectedTable).value;
                const row_value_tags = (row.get(column_index_tags[0]) catch return error.UnexpectedTable).value;

                // convert table representation of tags into []const u8
                var tags_iterator = std.mem.split(u8, row_value_tags, " ");
                var tags = ArrayList([]const u8).init(allocator);
                while (tags_iterator.next()) |tag| if (tag.len != 0) {
                    try tags.append(try allocator.dupe(u8, tag));
                };

                return Idea{
                    .allocator = allocator,
                    .id = idea_id,
                    .title = try allocator.dupe(u8, row_value_title),
                    .reference = try allocator.dupe(u8, row_value_reference),
                    .content = try self.readContentFromReference(allocator, row_value_reference),
                    .progress = IdeaProgress.fromString(row_value_progress) orelse return error.UnexpectedTable,
                    .tags = tags.toOwnedSlice(),
                };
            }
        }

        return error.InvalidID;
    }

    /// Add an idea to the on-disk IdeaBook, returning the idea's ID
    pub fn addIdea(self: IdeaBook, idea: anytype) IdeaBookError!usize {
        const idea_reference = try self.stashContent(self.allocator, idea.content);
        defer self.allocator.free(idea_reference);

        const idea_id = try self.nextID();

        try self.pushTableEntry(.{
            .id = idea_id,
            .title = idea.title,
            .reference = idea_reference,
            .progress = idea.progress,
            .tags = idea.tags,
        });

        return idea_id;
    }

    /// Remove an idea from the lookup table, leaving invalid references behind
    pub fn removeIdea(self: IdeaBook, idea_id: usize) IdeaBookError!void {
        try self.popTableEntry(idea_id);
    }

    /// Replace the title of an existing idea with a new title
    pub fn editIdeaTitle(self: IdeaBook, idea_id: usize, new_idea_title: []const u8) IdeaBookError!void {
        const idea = try self.readIdea(self.allocator, idea_id);
        defer idea.deinit();

        try self.popTableEntry(idea_id);
        try self.pushTableEntry(.{
            .id = idea.id,
            .title = new_idea_title,
            .reference = idea.reference,
            .progress = idea.progress,
            .tags = idea.tags,
        });
    }

    /// Replace the content of an existing idea with a new content, storing it on-disk
    pub fn editIdeaContent(self: IdeaBook, idea_id: usize, new_idea_content: []const u8) IdeaBookError!void {
        const idea = try self.readIdea(self.allocator, idea_id);
        defer idea.deinit();

        const idea_reference = try self.stashContent(self.allocator, new_idea_content);
        defer self.allocator.free(idea_reference);

        try self.popTableEntry(idea_id);
        try self.pushTableEntry(.{
            .id = idea.id,
            .title = idea.title,
            .reference = idea_reference,
            .progress = idea.progress,
            .tags = idea.tags,
        });
    }

    /// Replace the progress of an existing idea with an updated progress state
    pub fn editIdeaProgress(self: IdeaBook, idea_id: usize, new_idea_progress: IdeaProgress) IdeaBookError!void {
        const idea = try self.readIdea(self.allocator, idea_id);
        defer idea.deinit();

        try self.popTableEntry(idea_id);
        try self.pushTableEntry(.{
            .id = idea.id,
            .title = idea.title,
            .reference = idea.reference,
            .progress = new_idea_progress,
            .tags = idea.tags,
        });
    }

    /// Replace the tags of an existing idea with new tags
    pub fn editIdeaTags(self: IdeaBook, idea_id: usize, new_idea_tags: []const []const u8) IdeaBookError!void {
        const idea = try self.readIdea(self.allocator, idea_id);
        defer idea.deinit();

        try self.popTableEntry(idea_id);
        try self.pushTableEntry(.{
            .id = idea.id,
            .title = idea.title,
            .reference = idea.reference,
            .progress = idea.progress,
            .tags = new_idea_tags,
        });
    }

    /// Return an IdeaIterator that provides methods for querying and iterating over the stashed ideas
    pub fn iterateIdeas(self: IdeaBook) IdeaBookError!IdeaIterator {
        return IdeaIterator{
            .parent = self,
            .last_id = try self.nextID() - 1,
        };
    }
};
