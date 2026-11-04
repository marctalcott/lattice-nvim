# Instructions for AI coding agents — Lattice

## Project boundary

This repository is Lattice, an independent Neovim/LazyVim plugin. Portico is a different project. Do not inspect, modify, import from, or commit to any Portico repository, nor assume the Portico directory is the working directory. If started from inside Portico, stop and switch to the Lattice repository before writing files.

## Product constraints

- Implement in Lua for Neovim; support configuration from LazyVim.
- Keep the user's PARA folder structure unchanged.
- Existing Markdown notes remain the sole source of truth for tasks.
- Scanning is read-only (it may read unsaved open buffers). Notes change only on an explicit user action, through the mutation layer (lua/lattice/mutate.lua), and only in buffers: commands edit the current note; refile, archive and dashboard row edits may also change another note's buffer. Lattice never writes a file except when the user saves, including the dashboard's `s`. Never create folders.
- No new database, Electron application, backend service, account, AI SDK, or cloud integration in v0.1.
- Honor .lattice.json include/exclude patterns relative to the notes root, excluding Archives/** by default.
- Recognize tasks as Org-mode does (specs/LATTICE_SYNTAX_SPEC.md §3 with Amendment 1): only headings that start with a workflow state are tasks; checkboxes are steps that count toward progress. Structure comes from Neovim's Tree-sitter Markdown parser. Write only Org forms (headings, planning lines, drawers). Keep reading Lattice v0.1 syntax (Waiting On sections, `@Name`, `[due:]`, `[promised:]`, front matter `todo:`) as specs/ORG_MARKDOWN_PLAN.md D3 describes.
- Source links must open the original file at its actual line.

## Development approach

Read specs/product-vision.md for the full intent, then specs/LATTICE_SPEC.md for the Milestone 1 implementation contract (it supersedes specs/lattice-v0.1.md where they differ). Work after v0.1.0 follows specs/LATTICE_SYNTAX_SPEC.md (Org-mode semantics over Markdown, v0.2) and the decisions in specs/ORG_MARKDOWN_PLAN.md; where they differ from LATTICE_SPEC.md, they win. Test fixtures for that work use volcano project names and invented people. Do not implement deferred requirements unless explicitly requested. Implement smallest viable scanner and UI. Add automated tests for task parsing, heading boundaries, exclusion patterns, completion detection, and source navigation. Keep dependencies minimal; do not alter user notes simply because a scan ran. Ask before introducing a new persistent file format or deviating from the spec.

Run the tests with `nvim -l tests/run.lua`.
