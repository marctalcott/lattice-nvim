# Instructions for AI coding agents — Lattice

## Project boundary

This repository is Lattice, an independent Neovim/LazyVim plugin. Portico is a different project. Do not inspect, modify, import from, or commit to any Portico repository, nor assume the Portico directory is the working directory. If started from inside Portico, stop and switch to the Lattice repository before writing files.

## Product constraints

- Implement in Lua for Neovim; support configuration from LazyVim.
- Keep the user's PARA folder structure unchanged.
- Existing Markdown notes remain the sole source of truth for tasks.
- Scanning and dashboard navigation are read-only; insertion commands only edit the current note after an explicit user action.
- No new database, Electron application, backend service, account, AI SDK, or cloud integration in v0.1.
- Honor .lattice.json include/exclude patterns relative to the notes root, excluding Archives/** by default.
- Recognize tasks strictly: items whose first word is a declared org-style TODO keyword (exact case; sequences from `todo` in .lattice.json, overridable per note by YAML front matter `todo:`), and bullets under headings named exactly Waiting On (case-sensitive, after trimming surrounding whitespace) at any heading level. See Amendment A in specs/LATTICE_SPEC.md.
- Source links must open the original file at its actual line.

## Development approach

Read specs/product-vision.md for the full intent, then specs/LATTICE_SPEC.md for the Milestone 1 implementation contract (it supersedes specs/lattice-v0.1.md where they differ). Do not implement deferred requirements unless explicitly requested. Implement smallest viable scanner and UI. Add automated tests for task parsing, heading boundaries, exclusion patterns, completion detection, and source navigation. Keep dependencies minimal; do not alter user notes simply because a scan ran. Ask before introducing a new persistent file format or deviating from the spec.

Run the tests with `nvim -l tests/run.lua`.
