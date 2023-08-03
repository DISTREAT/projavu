//! This module provides unit tests for lib.zig
//! [Released under GNU LGPLv3]
//!
const std = @import("std");
const projavu = @import("lib.zig");
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;

/// A testing environment to quickly test IdeaBook methods
const TestingEnvironment = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    tmp_path: []const u8,
    ideabook: projavu.IdeaBook,

    /// Initialize a testing environment, containing a temporary and already usable IdeaBook
    pub fn init(allocator: std.mem.Allocator) anyerror!TestingEnvironment {
        var tmp_dir = std.testing.tmpDir(.{});

        const ideabook = projavu.IdeaBook{
            .allocator = allocator,
            .root = tmp_dir.dir,
            .table_basename = "table.csv",
        };

        try ideabook.initializeTable();

        return TestingEnvironment{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .tmp_path = try tmp_dir.dir.realpathAlloc(allocator, "."),
            .ideabook = ideabook,
        };
    }

    /// Free all used memory and close the temporary ideabook, deleting its data
    pub fn deinit(self: *TestingEnvironment) void {
        self.tmp_dir.cleanup();
        self.allocator.free(self.tmp_path);
    }
};

/// Generate a random idea that can also be tested against other ideas
const RandomIdea = struct {
    // Allows for the fields to be slices to prevent odd conversions
    allocator: std.mem.Allocator,
    title: []const u8,
    content: []const u8,
    progress: projavu.IdeaProgress,
    tags: []const []const u8,

    const title_size = 100;
    const content_size = 1000;
    const max_amount_tags = 15;
    const tags_item_size = 20;

    /// Generate a slice of random letters
    fn randomData(allocator: std.mem.Allocator, comptime size: usize) anyerror![]const u8 {
        var buf: [size]u8 = undefined;

        var index: usize = 0;
        while (index < size) : (index += 1) {
            const random_index = std.crypto.random.intRangeAtMost(usize, 0, 25); // alphabet.len - 1
            buf[index] = "abcdefghijklmnopqrstuvwxyz"[random_index];
        }

        return try allocator.dupe(u8, &buf);
    }

    /// Return a random field of enum IdeaProgress
    fn randomIdeaProgress() projavu.IdeaProgress {
        return @intToEnum(
            projavu.IdeaProgress,
            std.crypto.random.intRangeAtMost(
                usize,
                0,
                @typeInfo(projavu.IdeaProgress).Enum.fields.len - 1,
            ),
        );
    }

    /// Generate a slice of slices, containing random letters
    fn randomTags(allocator: std.mem.Allocator) anyerror![]const []const u8 {
        var tags = std.ArrayList([]const u8).init(allocator);

        var index: usize = 0;
        while (index < max_amount_tags) : (index += 1) {
            const tag = try RandomIdea.randomData(allocator, tags_item_size);
            try tags.append(tag);
        }

        return tags.toOwnedSlice();
    }

    /// Generate a random Idea
    pub fn generate(allocator: std.mem.Allocator) anyerror!RandomIdea {
        return RandomIdea{
            .allocator = allocator,
            .title = try RandomIdea.randomData(allocator, title_size),
            .content = try RandomIdea.randomData(allocator, content_size),
            .progress = RandomIdea.randomIdeaProgress(),
            .tags = try RandomIdea.randomTags(allocator),
        };
    }

    /// Free all the memory used by the random Idea
    pub fn deinit(self: RandomIdea) void {
        self.allocator.free(self.title);
        self.allocator.free(self.content);
        for (self.tags) |tag| self.allocator.free(tag);
        self.allocator.free(self.tags);
    }

    /// Verify that the generated idea is equal to the provided idea
    pub fn expect_match(self: RandomIdea, idea: projavu.Idea) anyerror!void {
        try expect(std.mem.eql(u8, idea.title, self.title));
        try expect(std.mem.eql(u8, idea.content, self.content));
        try expect(idea.progress == self.progress);

        for (idea.tags) |tag, index| {
            try expect(std.mem.eql(u8, tag, self.tags[index]));
        }
    }
};

test "Append random ideas to an on-disk IdeaBook and retrieve the idea's stored data" {
    var test_env = try TestingEnvironment.init(testing_allocator);
    defer test_env.deinit();

    comptime var iteration: usize = 0;
    inline while (iteration < 50) : (iteration += 1) {
        const random_idea = try RandomIdea.generate(testing_allocator);
        defer random_idea.deinit();

        const idea_id = try test_env.ideabook.addIdea(.{
            .title = random_idea.title,
            .content = random_idea.content,
            .progress = random_idea.progress,
            .tags = random_idea.tags,
        });

        const idea = try test_env.ideabook.readIdea(testing_allocator, idea_id);
        defer idea.deinit();

        try expect(idea.id == idea_id);
        try random_idea.expect_match(idea);
    }
}

test "Stash a random idea and edit every detail afterwards, verifying that the information was changed" {
    var test_env = try TestingEnvironment.init(testing_allocator);
    defer test_env.deinit();

    const random_original_idea = try RandomIdea.generate(testing_allocator);
    defer random_original_idea.deinit();

    const idea_id = try test_env.ideabook.addIdea(.{
        .title = random_original_idea.title,
        .content = random_original_idea.content,
        .progress = random_original_idea.progress,
        .tags = random_original_idea.tags,
    });

    const random_target_idea = try RandomIdea.generate(testing_allocator);
    defer random_target_idea.deinit();

    try test_env.ideabook.editIdeaTitle(idea_id, random_target_idea.title);
    try test_env.ideabook.editIdeaContent(idea_id, random_target_idea.content);
    try test_env.ideabook.editIdeaProgress(idea_id, random_target_idea.progress);
    try test_env.ideabook.editIdeaTags(idea_id, random_target_idea.tags);

    const idea = try test_env.ideabook.readIdea(testing_allocator, idea_id);
    defer idea.deinit();

    try expect(idea.id == idea_id);
    try random_target_idea.expect_match(idea);
}

test "Stash a couple of random ideas and delete a random one afterwards, verifying its non-existence and the integrity of the untouched ideas" {
    var test_env = try TestingEnvironment.init(testing_allocator);
    defer test_env.deinit();

    var ids = std.ArrayList(usize).init(testing_allocator);
    defer ids.deinit();

    comptime var iteration: usize = 0;
    inline while (iteration < 10) : (iteration += 1) {
        const random_idea = try RandomIdea.generate(testing_allocator);
        defer random_idea.deinit();

        const idea_id = try test_env.ideabook.addIdea(.{
            .title = random_idea.title,
            .content = random_idea.content,
            .progress = random_idea.progress,
            .tags = random_idea.tags,
        });

        try ids.append(idea_id);
    }

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const idea_allocator = arena.allocator();

    // cleanInvalidReferences should not touch a single idea, thus no error.InvalidID
    for (ids.items) |id| _ = try test_env.ideabook.readIdea(idea_allocator, id);

    // delete a random idea and check if it's in accessible
    const random_index = std.crypto.random.intRangeAtMost(usize, 0, ids.items.len - 1);
    const random_id = ids.items[random_index];

    try test_env.ideabook.removeIdea(random_id);
    try test_env.ideabook.cleanInvalidReferences();

    try expect(test_env.ideabook.readIdea(idea_allocator, random_id) == error.InvalidID);

    _ = ids.orderedRemove(random_index);

    // no other ideas should have been touched
    for (ids.items) |id| _ = try test_env.ideabook.readIdea(idea_allocator, id);
}

test "Stash random ideas and iterate over them" {
    var test_env = try TestingEnvironment.init(testing_allocator);
    defer test_env.deinit();

    const random_idea_1 = try RandomIdea.generate(testing_allocator);
    defer random_idea_1.deinit();
    const random_idea_2 = try RandomIdea.generate(testing_allocator);
    defer random_idea_2.deinit();

    _ = try test_env.ideabook.addIdea(.{
        .title = random_idea_1.title,
        .content = random_idea_1.content,
        .progress = random_idea_1.progress,
        .tags = random_idea_1.tags,
    });

    _ = try test_env.ideabook.addIdea(.{
        .title = random_idea_2.title,
        .content = random_idea_2.content,
        .progress = random_idea_2.progress,
        .tags = random_idea_2.tags,
    });

    var idea_iterator = try test_env.ideabook.iterateIdeas();

    const idea_1 = (try idea_iterator.next()).?;
    defer idea_1.deinit();
    const idea_2 = (try idea_iterator.next()).?;
    defer idea_2.deinit();

    try random_idea_1.expect_match(idea_1);
    try random_idea_2.expect_match(idea_2);
    try expect(try idea_iterator.next() == null);
}
