# projavu

A program for on-disk storing and managing of project ideas.

_Build using zig version: `0.10.1`_

## Features

- Display ideas similar to [taskwarrior](https://taskwarrior.org/)
- Filter ideas to only show relevant entries
- Categorize projects based on development progress
- Assign tags to projects
- Editor-focused workflow

## Backend

- All noted ideas are stored on-disk via a hash-calculated path
- A CSV table is used to reference ideas, store tags, and progress
- On-disk content is only deleted when not referenced anymore and the garbage collector is manually run
- The underlying library is undergoing decent integration-testing.

## Binaries

Binaries and checksums are provided with every release.

[Releases](https://github.com/DISTREAT/projavu/releases)

## Documentation

This repository contains both a CLI and library interface.

The documentation for the library is created in the directory `docs/` when running `zig build`.

[Documentation](https://distreat.github.io/projavu/)

