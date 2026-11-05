# Lattice Inbox — Technical Specification

- Version: 1.0 with Amendment 1
- Status: Amendment 1 approved by the product owner (2026-11-05); not yet implemented
- Parent project: Lattice (Neovim/LazyVim plugin)
- Components: Drafts iOS action, GitHub capture repositories, Lattice Inbox module
- Related documents: [`product-vision.md`](product-vision.md) §5.4, [`LATTICE_SPEC.md`](LATTICE_SPEC.md) §11 Milestone 6 and §12, [`LATTICE_SYNTAX_SPEC.md`](LATTICE_SYNTAX_SPEC.md), [`ORG_MARKDOWN_PLAN.md`](ORG_MARKDOWN_PLAN.md)

The product owner (PO) wrote the specification below (v1.0, 2026-11-05). Amendment 1 adapts it to Lattice's existing constraints and settles its open implementation decisions (§19). **Where the amendment and the sections below differ, the amendment wins.**

---

## Amendment 1 — Fitting the inbox to Lattice (2026-11-05)

A1.1 and A1.2 were decided by the PO. The rest were proposed by the developer to resolve conflicts with AGENTS.md or fill gaps in the spec, and the PO approved all of them on 2026-11-05.

### A1.1 GitHub sync replaces the local-folder decision (PO, 2026-11-05)

This spec supersedes the 2026-11-01 decision in `product-vision.md` §5.4 ("how files reach that folder is outside Lattice"). Lattice fetches captures from GitHub and deletes processed captures there.

- **Opt-in.** Lattice makes network calls only when the inbox configuration file (A1.4) exists and lists at least one enabled repository. That file is the explicit opt-in required by `LATTICE_SPEC.md` §12. Without it, Lattice makes no network access, and nothing else in Lattice depends on the inbox.
- **The local inbox folder stays.** The dashboard's INBOX group (`inbox.path` in `.lattice.json`) keeps working unchanged, for captures that arrive by other means. The GitHub inbox is a separate view (A1.10).

### A1.2 Save-triggered filing (PO, 2026-11-05)

Lattice still never writes a file itself (AGENTS.md). Filing and task conversion are two-phase, and **the user's save is the commit point**:

1. **Prepare.** File (§8.4.1) or Convert to Task (§8.4.2) opens a **new, unsaved buffer** named with the destination path (A1.8), holding the generated note (A1.3). Lattice creates no file and no folder. Its buffer-local state records the capture's repository and ID.
2. **Review.** The user may edit anything, including the title, before saving. Closing the buffer without saving abandons filing: the capture stays in the inbox and on GitHub.
3. **Commit.** On that buffer's `BufWritePost`, Lattice reads the file back from disk and checks that it contains a `:CAPTURE_ID:` property equal to the capture's ID. If it does, the capture is marked *filed* and its remote deletion starts (A1.6). If it does not (the user removed the property, or the write went elsewhere), Lattice warns and does not delete anything.
4. **No overwrite.** The destination path is chosen so no file exists there (A1.8). If one appears before the save, Neovim's own `E13: File exists` refuses the write. Lattice never offers `:w!`.

Lattice checks only the capture ID, not the body. Edits the user makes before saving are their explicit choice, which is allowed under §4.3 because nothing is rewritten automatically.

### A1.3 Format of a filed note (PO, 2026-11-05)

Lattice writes only Org forms (AGENTS.md), so capture metadata goes in a property drawer, not YAML front matter:

```markdown
# Project organization idea
:PROPERTIES:
:CAPTURE_ID: 3f1c9a52-7d0e-4b8a-9c11-5e2f0d7a4b6e
:CAPTURED: 2026-11-05T07:45:00-05:00
:CAPTURE_SOURCE: drafts
:CAPTURE_REPO: Personal
:END:

I was thinking about a better way to organize
the project notes when I get back to my computer.
```

- The body is the capture's text after its front matter, byte for byte, except that a trailing newline is added if it is missing.
- `:CAPTURED:` copies the capture's `created` value verbatim. It is not converted to an Org timestamp, so the original offset is preserved.
- **Convert to Task** produces the same note with the heading `# TODO <title>`. Under Amendment 1 of `LATTICE_SYNTAX_SPEC.md`, only headings are tasks, so no checkbox form is offered (this replaces "Support Markdown headings and checkbox tasks" in §11.4). The keyword is the first active state of the `default` workflow. The new note has no `:PROJECT:` and no project heading, so no other workflow applies (`ORG_MARKDOWN_PLAN.md` D2). The user can change the state before saving.

### A1.4 Configuration file (PO, 2026-11-05 — a new persistent format, approved)

- Location: `~/.config/lattice/inbox.json` (`$XDG_CONFIG_HOME/lattice/inbox.json` when that is set), overridable with `setup({ inbox_sync = { config = "<path>" } })`.
- The format is **JSON, not TOML**. Neovim parses JSON natively (`vim.json`), and `.lattice.json` already uses it. TOML would need a hand-written parser or a new dependency. The keys are those of §5.2:

```json
{
  "inbox": {
    "auto_fetch": true,
    "sort_order": "newest_first",
    "notification_duration_ms": 3000,
    "default_folder": "Resources"
  },
  "repositories": [
    {
      "name": "Personal",
      "url": "git@github.com:personal-user/lattice-inbox.git",
      "branch": "main",
      "directory": "captures",
      "enabled": true,
      "notes_root": "~/Notes/Personal",
      "aliases": { "Projects/Etna": ["etna", "lava dome"] }
    }
  ]
}
```

- **Dropped keys.** `group_by` is dropped because grouping is always by repository. `delete_after_processing` is dropped because deletion is always on (§12.1).
- **Repository names** must be unique and non-empty.
- **`url`** may be any Git remote URL (HTTPS or SSH), not only `https://github.com/…`. This is what lets two github.com accounts use separate credentials (A1.7).
- **`directory`** must be relative and must not contain `..`.
- **`aliases`** maps an existing folder (relative to `notes_root`) to extra keywords for folder suggestions (A1.9).
- **`default_folder`** is relative to each repository's `notes_root`. It must exist, and it must not be the `.lattice.json` `inbox.path` folder or inside it. Otherwise a filed capture would show up again as unprocessed in the dashboard's INBOX group. The default is `Resources`; this replaces `Inbox` in §10.4.
- **Validation errors** name the file, the repository and the key. An invalid file disables the inbox and is reported once. It never blocks the rest of Lattice.
- **Migration.** The file has no version key in v1. A future incompatible change adds `"version": 2`.

### A1.5 One notes root at a time (PO, 2026-11-05)

Lattice has one notes root per session (`setup({ root = … })`). A repository is **active** only when its `notes_root` resolves (via realpath) to that root. Lattice fetches, lists and files only active repositories. `:LatticeInboxStatus` lists the rest as "other notes root". This satisfies §5.5 and §15.2 structurally: a capture can only be filed under its own repository's root. Supporting several roots in one session is out of scope.

### A1.6 Synchronization with the Git CLI (PO, 2026-11-05) — §19.2, §19.3, §19.7

- **Cache.** Each active repository has a shallow clone at `stdpath("cache")/lattice/inbox/<name>-<8 hex of sha256(url)>`, checked out with sparse-checkout limited to `directory`. The clone is the cache (§7). It is disposable: if it is missing or damaged, Lattice deletes and re-clones it. It is never the only copy of an unprocessed capture, because the capture stays on GitHub until deletion succeeds.
- **Fetch.** Lattice runs `git fetch --depth 1 origin <branch>`, then `git reset --hard FETCH_HEAD`, using `vim.system` asynchronously. It processes at most 4 repositories at once and gives each command a 30-second timeout. Unchanged repositories download nothing.
- **No prompts.** Every git call sets `GIT_TERMINAL_PROMPT=0` and runs detached from the terminal (its own session, with no controlling TTY), so neither git nor ssh can prompt over Neovim's screen; missing credentials fail fast. Lattice does not override `GIT_SSH_COMMAND`, so a user's `core.sshCommand` (often how a work SSH identity is chosen) keeps working.
- **Credentials.** For HTTPS URLs, Lattice passes `-c credential.useHttpPath=true`, so credential helpers can key credentials per repository.
- **New captures (§6.2).** A capture is new if its ID was not in that repository's file list before the fetch. On a first clone, every capture counts as new.
- **Deletion (§12, §8.4.4).** Lattice runs `git rm` on the capture, commits with the message `Lattice: remove processed capture <file>` under the user's Git identity, and pushes.
  - If the push is rejected as non-fast-forward (for example, Drafts uploaded something meanwhile), Lattice fetches, resets to `FETCH_HEAD`, repeats the `git rm` and pushes again, up to 3 attempts. A capture that is already gone counts as deleted.
  - Any other rejection, such as branch protection or a permission error, leaves the capture listed as **filed, removal pending**. The error is shown, and the next fetch retries the deletion.
- **Errors.** A repository's error (authentication, network, timeout, invalid capture) is recorded against that repository only and shown by `:LatticeInboxStatus`.
- **Rate limits.** Lattice uses no GitHub REST API on the desktop, so API rate limits do not apply. Git transport limits show up as ordinary fetch errors.

### A1.7 Separate credentials for personal and work (PO, 2026-11-05)

Credential helpers key on the host, and both accounts live on github.com. The documented setup is:

- **Either:** an SSH host alias for the work account in `~/.ssh/config` (`Host github-work`, with its own `IdentityFile`), with `url = "git@github-work:work-org/lattice-inbox.git"`;
- **Or:** HTTPS with a helper that honours `useHttpPath`.

Lattice stores no credentials and never logs URLs that contain credentials (any `user:pass@` part is redacted from messages).

### A1.8 Titles and filenames (PO, 2026-11-05) — §19.5

**Title**, computed once per capture per session and then cached:

1. Take the first non-empty line of the body. Cut it at the first `.`, `?` or `!` that is followed by a space or the end of the line.
2. Strip leading Markdown markers (`#`, `-`, `*`, `>`, `[ ]`) and surrounding whitespace.
3. Drop one leading filler phrase, case-insensitively, from a fixed list: "I was thinking about", "I was thinking", "I think", "I need to", "Note to self", "Remember to", "Maybe we should", "So".
4. Limit the result to 8 words and 60 characters, cutting at a word boundary. Capitalize the first letter and leave the rest unchanged, so dictated proper nouns survive.
5. If nothing remains, use `Capture YYYY-MM-DD HHMM` from `created`.

The user edits the title with `vim.ui.input`, prefilled with the suggestion.

**Filename:**

- Remove `/ \ : * ? " < > |`, control characters and leading dots from the title, and collapse whitespace.
- Cut it to 80 bytes and add `.md`.
- If that name exists in the destination folder, try `<name> 2.md`, `<name> 3.md`, and so on.
- The final path is checked to resolve inside the repository's `notes_root` (§15.3).

### A1.9 Folder suggestions (PO, 2026-11-05) — §10

- **Candidates.** The candidates are the directories that already exist under the notes root, at depth 1 and 2. Lattice skips hidden directories, anything matched by `.lattice.json` `scan.exclude`, and the `inbox.path` folder.
- **Keywords.** A candidate's keywords are its own folder name, plus its `aliases` from A1.4.
- **Scoring.** A candidate's score is the number of whole-word, case-insensitive matches of its keywords in the capture body.
- **Choice.** The highest score wins. Ties go to the deeper folder, then alphabetical order. A score of 0 suggests `default_folder`.
- **No learning.** Nothing is learned or stored, so the same capture and configuration always give the same suggestion (§10.3).
- **Picker.** The folder picker (`vim.ui.select`) lists the suggestion first and then every candidate. Lattice never creates a folder. Cancelling cancels filing.
- **Diagnostics.** The optional diagnostic command in §10.5 is deferred.

### A1.10 Inbox view and commands (PO, 2026-11-05) — §8, §13

`:LatticeInbox` opens a scratch buffer, separate from the dashboard, that lists active repositories as groups with their captures sorted newest first by `created`.

| Key | Action |
|-----|--------|
| `Enter` | On a group: collapse or expand it. On a capture: show the read-only preview (§8.3) in a split. |
| `f` | File (A1.2) |
| `t` | Convert to Task (A1.2, A1.3) |
| `o` | Open the cached capture in a `readonly`, `nomodifiable` buffer. This does not process it. |
| `D` | Dismiss: ask for confirmation, then delete the capture remotely (A1.6) |
| `R` | Refresh |
| `q` | Close |

- **Commands.** `:LatticeInbox` and `:LatticeInboxRefresh` are added, along with `:LatticeInboxStatus`, which shows each repository's state, last successful fetch, error and any pending removals.
- **Default mappings.** `<leader>li` opens the inbox. `<leader>lR` refreshes it, because §13's suggested `<leader>lr` is already `:LatticeRefresh`. Both use `setup({ keymaps = … })` like the existing ones, and Lattice never overrides a mapping the user has set.
- **Malformed captures.** A capture without a front-matter `id` is listed with a warning and can be opened or dismissed, but not filed.
- **Unsafe paths.** Capture paths from the repository must be regular files matching `[%w._-]+%.md` directly under `directory`. Symlinks and other names are skipped and reported.

### A1.11 Startup and notifications (PO, 2026-11-05) — §6

- The startup fetch runs on `VimEnter`, only when `auto_fetch` is true and Neovim has a UI. It never runs in headless or `nvim -l` sessions.
- The notification uses `vim.notify(msg, level, { title = "Lattice Inbox", timeout = notification_duration_ms })`. With LazyVim's notifier (snacks.nvim) or nvim-notify, the timeout is honoured. With plain Neovim the message appears in the command line and stays in `:messages`, so the 3-second disappearance is best effort.
- If any repository failed, the notification is a warning: `Lattice Inbox: 3 new captures (1 repository failed — :LatticeInboxStatus)`. It never reports a complete sync when a repository failed (§6.4).
- A manual refresh is silent on success and reports errors only.

### A1.12 Recovery and idempotency (PO, 2026-11-05) — §19.4

No journal file is kept. The filed note itself records that processing happened:

- **Startup recovery.** On each fetch, Lattice looks up every listed capture's ID in the scan index (the `:CAPTURE_ID:` property). A capture whose ID already appears in a note under its root is marked *filed, removal pending*, and its deletion is retried instead of offering it for filing again. This covers a crash between save and deletion, a failed deletion, and reprocessing (§12.3).
- **Unrecoverable cases.** The lookup uses the normal scan, so a note in an excluded folder (such as `Archives/**`) is not found. Moving a freshly filed note into an excluded folder before its capture is removed would offer the capture again. This is accepted as unlikely.
- **Unavailable destination.** If the destination filesystem is unavailable, the write fails in Neovim, no `BufWritePost` happens, and nothing is deleted.

### A1.13 Drafts action (PO, 2026-11-05) — §3, §19.1

- **Location.** The action lives in this repository under `drafts/` (`send-to-github.js` and `README.md` with installation steps). It is JavaScript run by Drafts, independent of the plugin, and works without Lattice (Phase 1).
- **Destinations.** They are configured as JSON in a *Define Template Tag* step named `lattice_destinations`, which is separate from the script step (§3.3). Each entry has `name`, `id` (the `destination` written into front matter), `owner`, `repo`, `branch` and `directory`.
- **Credentials.**
  - Each destination has its own Drafts `Credential`, identified as `Lattice <name>`, holding one fine-grained personal access token. The token is limited to that one repository with *Contents: read and write*.
  - Organizations may require token approval or SAML SSO authorization. The README covers this. Replacing a token means editing the credential in Drafts, with no change to the script.
- **Choosing a destination.** Each run shows a `Prompt` with one button per destination, so the destination is chosen every time.
- **Capture ID and filename.** The ID is the draft's `uuid`, lowercased. The filename is `YYYY-MM-DD-HHMMSS-<first 8 hex of the uuid>.md`, built from `draft.createdAt` in local time, and `created` is ISO 8601 with a `±HH:MM` offset. Both are stable across retries (§3.6).
- **Upload.** `PUT https://api.github.com/repos/{owner}/{repo}/contents/{directory}/{filename}` with no `sha`, so GitHub never overwrites a file.
  - **201:** archive the draft (`draft.isArchived = true; draft.update()`) and show a success message.
  - **422** (the file exists): `GET` the file. If its front-matter `id` equals this draft's ID, an earlier attempt succeeded, so archive. Otherwise report a collision and do not archive.
  - **Anything else, including network failure:** show the status code and GitHub's message, never the token, and do not archive.

### A1.14 Delivery

There is one pull request per phase of §16, and the plugin keeps working after each one. Dismissal (§8.4.4, `D`) needs the same remote deletion as filing, so it lands in Phase 4 with that deletion rather than in Phase 3. Phase 1 (A1.13) can land independently. Phases 2–4 add tests in `tests/inbox_spec.lua` covering the following:

- configuration validation;
- title and filename rules;
- folder scoring and ties;
- path-safety checks;
- the new-capture count;
- recovery by `:CAPTURE_ID:`.

Git operations are tested against a local bare repository standing in for GitHub, with no network.

---

## 1. Overview

Lattice Inbox provides a simple way to capture thoughts on an iPhone and import them into a Markdown-based note system managed through Neovim.

The user captures notes using the Drafts iOS application. Drafts uploads each capture as a Markdown file to a private GitHub repository.

When Neovim starts, Lattice automatically retrieves new captures from all configured GitHub inbox repositories and presents them in an organized interface.

The user reviews each capture, optionally converts it into a task, and files it into their existing PARA Markdown notes structure.

### Core design principles

1. Capture quickly with minimal interaction.
2. Use Drafts rather than building a custom iPhone application.
3. Keep GitHub as the synchronization mechanism.
4. Support any number of GitHub inbox repositories.
5. Keep personal and work repositories logically and securely separated.
6. Preserve original dictated content.
7. Use Markdown files as the permanent storage format.
8. Avoid AI dependencies, learning systems, and unnecessary complexity.
9. Integrate into the existing Lattice Neovim plugin.
10. Do not modify existing notes when filing captures; create new documents.

## 2. System Architecture

The system consists of three components.

### 2.1 Drafts iOS Action

Responsible for:

- Capturing dictated or typed notes.
- Displaying available GitHub destinations.
- Uploading Markdown files to the selected repository.
- Adding capture metadata.
- Archiving the Drafts note after confirmed successful upload.

### 2.2 GitHub Capture Repositories

Each repository acts as an incoming capture queue. Repositories:

- Are private.
- Contain individual Markdown capture files.
- Can belong to different GitHub accounts or organizations.
- Are configured independently.
- Are not the user's primary notes repositories.

The system must support one, two, twenty, or more configured repositories without an artificial application limit.

### 2.3 Lattice Inbox Module

Responsible for:

- Reading repository configuration.
- Fetching captures automatically.
- Grouping captures by source repository.
- Displaying and previewing captures.
- Generating suggested titles.
- Suggesting destination folders.
- Creating new Markdown notes or tasks.
- Removing processed captures from GitHub.
- Providing inbox counts and notifications.

Lattice operates within Neovim/LazyVim on macOS.

## 3. Drafts iOS Integration

### 3.1 User Workflow

1. Open Drafts.
2. Dictate or type a thought.
3. Save the draft.
4. Run the action named Send to GitHub.
5. Select the destination account/repository.
6. Drafts uploads the capture.
7. On confirmed success, Drafts archives the original draft.

The destination must be selected explicitly for each submission.

### 3.2 Multiple Destinations

The initial implementation must support a personal GitHub account and a work GitHub account. The architecture should allow additional destinations without requiring separate copies of the upload logic.

Each destination contains a display name, GitHub repository URL, authentication reference, target branch, and optional capture directory.

### 3.3 Drafts Configuration

Destination settings must be separate from the action's main upload logic. The implementation should provide a clearly documented configuration mechanism compatible with Drafts iOS scripting.

Example conceptual configuration (URLs are examples, not actual repositories):

```json
{
  "destinations": [
    { "name": "Personal", "repository": "https://github.com/personal-user/lattice-inbox", "branch": "main", "directory": "captures" },
    { "name": "Work", "repository": "https://github.com/work-org/lattice-inbox", "branch": "main", "directory": "captures" }
  ]
}
```

Drafts configuration and Lattice desktop configuration are separate because they operate on different devices.

### 3.4 Authentication

Each destination must use independent credentials. Requirements:

- Support private GitHub repositories.
- Use securely stored credentials or an appropriate authorization mechanism supported by Drafts.
- Never hardcode access tokens in action source code.
- Restrict permissions to the necessary repositories.
- Avoid exposing tokens in logs.
- Support token replacement without changing upload logic.
- Support GitHub organization authentication policies.

The developer must validate the chosen authentication mechanism against the installed Drafts version and GitHub organization requirements.

### 3.5 Successful Upload

A successful upload must: (1) create a new Markdown file; (2) confirm GitHub accepted the file creation; (3) display a brief success message; (4) archive the original Drafts note. Archiving must occur only after GitHub confirms success.

### 3.6 Failed Upload

If an upload fails: do not archive the Drafts note; preserve its contents; display a useful error message; allow the user to retry.

Retries must avoid creating duplicate captures. Use a stable capture ID and deterministic remote filename for retries. If the server outcome is uncertain, check whether the expected file already exists before attempting another upload.

## 4. Capture File Format

Each capture must create a separate Markdown file.

### 4.1 Filename

Use a timestamp and unique capture identifier, for example `2026-11-05-074500-a1b2c3.md`. Requirements: unique across captures; chronologically sortable; safe for Git filenames; stable across upload retries; never overwrite unrelated captures.

### 4.2 Markdown Structure

Use YAML front matter followed by the original captured text:

```markdown
---
id: "a1b2c3"
created: "2026-11-05T07:45:00-05:00"
source: "drafts"
destination: "personal"
---
I was thinking about a better way to organize
the project notes when I get back to my computer.
Maybe we should separate the meeting notes
from the actual project decisions.
```

Required metadata: unique capture ID; original creation timestamp; source application; selected destination identifier. The creation timestamp must represent when the Drafts note was created, not when the upload occurred. Additional metadata may be added without breaking compatibility.

### 4.3 Content Preservation

The system must preserve the dictated or typed content. Do not summarize it, rewrite it, correct its grammar automatically, generate a title on the iPhone, or interpret it as a task on the iPhone. Content interpretation happens later inside Lattice.

## 5. Lattice Inbox Configuration

*(Format and location amended by A1.4.)*

### 5.1 Dedicated Configuration File

The Lattice Inbox module must use a separate configuration file rather than embedding repository settings in the main LazyVim configuration. Proposed location: `~/.config/lattice/inbox.toml`. The exact location should be configurable. This file must contain the list of GitHub inbox repositories and module settings. Credentials must not be stored in this file.

### 5.2 Example Configuration

All paths and URLs are illustrative.

```toml
[inbox]
auto_fetch = true
group_by = "repository"
sort_order = "newest_first"
notification_duration_ms = 3000
default_folder = "Inbox"
delete_after_processing = true

[[repositories]]
name = "Personal"
url = "https://github.com/personal-user/lattice-inbox"
branch = "main"
directory = "captures"
enabled = true
notes_root = "~/Notes/Personal"

[[repositories]]
name = "Work"
url = "https://github.com/work-org/lattice-inbox"
branch = "main"
directory = "captures"
enabled = true
notes_root = "~/Notes/Work"
```

### 5.3 Configuration Requirements

The system must: support an arbitrary number of repositories; load repository definitions dynamically; allow repositories to be enabled or disabled; keep repository state independent; support different GitHub accounts and organizations; support different destination note roots; allow configuration changes without editing plugin source code; validate configuration and report useful errors.

### 5.4 Authentication

Lattice must use existing local Git authentication mechanisms where possible: Git credential helpers, SSH keys, or GitHub CLI authentication. Credentials must remain outside the inbox configuration. A failure to authenticate to one repository must not prevent other repositories from being fetched.

### 5.5 Personal and Work Isolation

Repository content must remain isolated. Each repository must have its own source configuration, authentication context, local processing state, destination notes root, and error status. Captures from one repository must never automatically be filed into another repository's destination root.

## 6. Automatic Fetching

### 6.1 Startup Behavior

When Neovim starts and Lattice initializes: (1) load the inbox configuration; (2) identify all enabled repositories; (3) fetch captures from each repository; (4) update local inbox state; (5) count newly imported captures; (6) display a temporary notification. Fetching should occur asynchronously so that Neovim remains responsive.

### 6.2 Notification

A notification must appear on startup regardless of whether any captures were imported, e.g. `Lattice Inbox: 0 new captures` or `Lattice Inbox: 20 new captures`. The notification should disappear automatically after approximately three seconds. The count represents newly fetched captures, not the total number of unprocessed captures.

### 6.3 Manual Refresh

Provide a configurable keyboard shortcut and command to fetch captures manually (suggested: `:LatticeInboxRefresh`). Manual refresh must fetch all enabled repositories, update the inbox, remain silent on success, and display errors when necessary. The normal startup notification must not appear during manual refresh.

### 6.4 Fetch Failure Handling

If one repository fails: continue processing the remaining repositories; preserve previously fetched captures; record the failure; provide an actionable error message. Do not report a successful complete synchronization if some repositories failed.

## 7. Local Capture Storage

Lattice should maintain a local cache of incoming captures. Requirements: keep each repository's cache separate; avoid duplicate imports; preserve unprocessed captures between Neovim sessions; do not modify the original GitHub capture during review; recover cleanly from interrupted fetches.

The cache must not be the only surviving copy of an unprocessed capture. A fetched capture remains in GitHub until processing is completed successfully.

## 8. Inbox User Interface

### 8.1 Grouping

The inbox must group captures by repository:

```
LATTICE INBOX
Personal (3)
  2026-11-05 07:45  Project organization idea
  2026-11-04 18:20  Photography notes
  2026-11-04 12:10  Weekend project
Work (2)
  2026-11-05 08:15  Deployment improvement
  2026-11-04 16:30  Meeting follow-up
```

The titles shown are generated during review or derived for display, not titles created by Drafts.

### 8.2 Group Behavior

Groups are collapsible; show the repository name; show the number of unprocessed captures; sort newest first within each group; allow keyboard navigation; allow a group to be expanded or collapsed.

### 8.3 Capture Selection

Selecting a capture opens a read-only preview displaying: suggested title; original capture date; source repository; original note content; suggested PARA destination folder; available processing actions.

### 8.4 Processing Actions

1. **File** — Create a new Markdown document in PARA.
2. **Convert to Task** — Create a new Lattice-compatible task.
3. **Open** — Open the capture in a Neovim buffer for inspection.
4. **Dismiss** — Discard the capture after confirmation.

Opening a capture must not itself mark it as processed. The original capture should remain unchanged during review.

## 9. Automatic Title Generation

*(Algorithm fixed by A1.8.)*

### 9.1 Trigger

Lattice must generate a suggested title as soon as a capture is selected. The title is generated locally.

### 9.2 Behavior

The title should be short and descriptive, reflect the captured content, be editable by the user, and be suitable for use as a Markdown heading and filename. Do not require AI services. Use deterministic rules such as extracting the first meaningful sentence or phrase, trimming it, and normalizing it for display. The developer may implement a simple fallback title based on the capture timestamp.

### 9.3 File Naming

When the user files a capture, the suggested title can be converted into a filesystem-safe filename, e.g. `Project Organization Idea.md`. If a filename already exists, generate a unique alternative. Never overwrite an existing document.

## 10. PARA Folder Suggestions

*(Algorithm fixed by A1.9; default folder amended by A1.4.)*

### 10.1 Objective

When a capture is selected, Lattice should suggest an appropriate folder in the configured PARA notes tree. The user must always be able to override the suggestion.

### 10.2 Matching Algorithm

Use simple deterministic matching. Possible signals: existing project folder names; existing area names; keywords in the captured text; explicit project names; configured aliases or keywords. No machine learning or AI is permitted.

### 10.3 No Learning

The folder suggestion mechanism must not learn from prior user selections. Do not track previous filing choices for recommendations, maintain adaptive ranking, train a model, update matching rules based on behavior, or display confidence scores. The same note and same configuration should produce the same folder suggestion.

### 10.4 Default Folder

If no suitable match is found, default to `Inbox`, resolved relative to the destination notes root configured for the capture's repository (e.g. `~/Notes/Personal/Inbox`).

### 10.5 User Interaction

Display only the suggested folder. The user may accept the suggestion, select another existing folder, or cancel filing. Do not show confidence scores or explanations unless requested through a separate diagnostic command.

## 11. Filing Captures

*(Mechanism amended by A1.2; note format by A1.3.)*

### 11.1 New Documents Only

Filing a capture must always create a new Markdown document. Do not append content to existing documents. Do not modify an existing Markdown note.

### 11.2 Filing Workflow

1. User selects a capture.
2. Lattice generates a suggested title.
3. Lattice suggests a PARA folder.
4. User reviews or edits the title.
5. User accepts or changes the destination folder.
6. Lattice creates a new Markdown file.
7. Lattice verifies that the file was written successfully.
8. Lattice deletes the original capture from GitHub.
9. Lattice removes the capture from the active inbox.

### 11.3 Content

The new Markdown document should contain the selected title, the original capture text, and relevant capture metadata. The original dictated content must remain intact. The developer should use the existing Lattice Markdown conventions where applicable.

### 11.4 Task Conversion

When converting a capture into a task: use Lattice's existing Org-mode-compatible task semantics; support Markdown headings and checkbox tasks; preserve the original captured content; allow the user to review the generated task before saving; create a new Markdown document; do not modify existing documents. Task conversion must not require an AI service.

## 12. Deleting Processed Captures

### 12.1 Default Behavior

Once a capture is successfully processed, delete its original Markdown file from the GitHub inbox repository. Do not move it into a processed directory.

### 12.2 Safe Deletion

Deletion must occur only after: (1) the destination Markdown document has been created; (2) its contents have been successfully written; (3) the resulting document has been verified; (4) the processing state has been recorded. If deletion fails, preserve the capture and report the failure.

### 12.3 Failure Recovery

The implementation must prevent accidental data loss. Special cases include: Neovim crashes after creating a file but before deleting the GitHub capture; network failure during deletion; GitHub rejects the deletion; destination file already exists; destination filesystem becomes unavailable. Processing must be idempotent. Reprocessing the same capture must not create duplicate notes.

### 12.4 Dismissal

Dismissal is a destructive operation. The user must confirm dismissal before GitHub deletion. After confirmation, Lattice deletes the capture from GitHub and removes it from the active inbox. If deletion fails, the capture remains available.

## 13. Keyboard Commands

*(Mappings amended by A1.10.)*

| Command | Purpose |
|---------|---------|
| `:LatticeInbox` | Open inbox |
| `:LatticeInboxRefresh` | Fetch captures |
| `:LatticeInboxStatus` | Show repository sync status |

| Shortcut | Action |
|----------|--------|
| `<leader>li` | Open inbox |
| `<leader>lr` | Refresh inbox |

All mappings must be configurable. The module must not override existing user keybindings without explicit configuration.

## 14. Performance Requirements

The implementation must: avoid blocking Neovim startup; fetch repositories independently; support at least 20 configured repositories; avoid downloading unchanged content unnecessarily; handle repositories with hundreds of captures; keep inbox navigation responsive; cache metadata where useful; avoid repeated title generation for the same unchanged capture within a session. Repository failures must not block the interface.

## 15. Security Requirements

### 15.1 Repository Access

Support private GitHub repositories. Use least-privilege credentials. Keep personal and work credentials separate. Never print credentials in logs. Never store credentials in Markdown front matter.

### 15.2 Content Isolation

Personal captures must remain within configured personal storage. Work captures must remain within configured work storage. The module must not automatically copy notes between personal and work destinations.

### 15.3 Local File Safety

Validate destination paths. Prevent path traversal. Avoid overwriting existing files. Validate GitHub repository configuration. Require confirmation for destructive actions. Ensure failed operations do not silently discard captures.

## 16. Implementation Phases

- **Phase 1 — Drafts Integration.** Drafts action named Send to GitHub; Personal and Work destination selection; configurable GitHub URLs; independent authentication; Markdown creation with metadata; automatic archiving after confirmed upload; retry and error handling. This phase must work without Lattice.
- **Phase 2 — Lattice Repository Synchronization.** Dedicated configuration file; support for multiple repositories; automatic startup fetching; startup capture count notification; manual refresh command; local cache; independent repository error handling.
- **Phase 3 — Lattice Inbox UI.** Repository-grouped inbox; collapsible groups; read-only capture preview; suggested titles; folder suggestions; keyboard navigation; filing, task conversion, opening, and dismissal actions.
- **Phase 4 — Processing and Cleanup.** Safe creation of new Markdown files; GitHub deletion after successful processing; idempotent processing; recovery from interrupted operations; integration with existing Lattice task semantics.

## 17. Acceptance Criteria

**Drafts**

- [ ] User can dictate a note in Drafts.
- [ ] User can choose Personal or Work.
- [ ] Note uploads to the correct private GitHub repository.
- [ ] Uploaded file contains valid Markdown and metadata.
- [ ] Original Drafts note is archived after successful upload.
- [ ] Failed uploads leave the note unarchived.
- [ ] Retrying does not create duplicate captures.

**Configuration**

- [ ] GitHub repository URLs are configured outside plugin source.
- [ ] Lattice uses a dedicated inbox configuration file.
- [ ] At least 20 repositories can be configured.
- [ ] Disabled repositories are skipped.
- [ ] Authentication is independent for each account.

**Synchronization**

- [ ] Lattice automatically fetches on startup.
- [ ] Fetching does not block Neovim.
- [ ] Startup notification appears even for zero new captures.
- [ ] Notification disappears after approximately three seconds.
- [ ] Manual refresh does not display a success notification.
- [ ] One failed repository does not prevent other repositories from syncing.

**Inbox**

- [ ] Captures are grouped by repository.
- [ ] Groups can be collapsed.
- [ ] Captures are sorted newest first.
- [ ] Selecting a capture opens a read-only preview.
- [ ] A suggested title is generated on selection.
- [ ] A destination folder is suggested using simple matching.
- [ ] No AI or learning is used.
- [ ] Unmatched captures default to the configured default folder (A1.4).

**Processing**

- [ ] Filing always creates a new Markdown document.
- [ ] Existing documents are never overwritten or appended to.
- [ ] Original capture content is preserved.
- [ ] Task conversion follows Lattice task syntax.
- [ ] GitHub captures are deleted after successful processing.
- [ ] Failed processing preserves the original capture.
- [ ] Interrupted operations can be recovered without duplication.
- [ ] Dismissal requires confirmation.

**Added by Amendment 1**

- [ ] Without an inbox configuration file, Lattice makes no network access.
- [ ] Closing an unsaved filing buffer leaves the capture in the inbox and on GitHub.
- [ ] Remote deletion starts only after a saved file containing the capture's `:CAPTURE_ID:` is read back.
- [ ] A capture whose ID already appears in a note is not offered for filing again; its deletion is retried.
- [ ] Lattice creates no folders and writes no files itself.

## 18. Out of Scope

The initial implementation will not include: a custom iPhone application; direct editing of existing notes from iPhone; two-way synchronization of the main notes repository; AI-based summarization; AI-based folder classification; machine learning from filing behavior; automatic modification of existing Markdown documents; web-based inbox management; background synchronization while Neovim is closed; collaboration or shared inbox assignment; automatic task extraction from arbitrary note text without user confirmation.

## 19. Open Implementation Decisions

*(Each is resolved by Amendment 1, as noted.)*

1. Exact Drafts action configuration and secure credential-storage mechanism. → A1.13
2. GitHub API versus Git CLI for Lattice synchronization. → A1.6 (Git CLI)
3. Local cache location and persistence format. → A1.6 (shallow clone in `stdpath("cache")`)
4. Transaction/recovery mechanism for processing and remote deletion. → A1.2, A1.12
5. Precise deterministic title-generation algorithm. → A1.8
6. Exact Markdown task-conversion format using existing Lattice conventions. → A1.3
7. Handling of GitHub rate limits, network timeouts, and organization policies. → A1.6, A1.7, A1.13
8. Configuration validation and migration strategy. → A1.4

These are implementation choices, not invitations to change the agreed user workflow.

## 20. Definition of Done

The feature is complete when the following workflow operates reliably:

**On iPhone:** Dictate a thought in Drafts, select a GitHub destination, upload the Markdown capture, and automatically archive the Drafts note.

**On Mac:** Open Neovim, allow Lattice to automatically fetch all configured repositories, receive a brief import-count notification, open the grouped inbox, review a capture, accept or change its suggested title and folder, and save it as a new Markdown note.

After successful processing, the original capture is deleted from GitHub.

The entire process must be reliable, keyboard-friendly, independent of AI, and compatible with the existing Lattice Markdown/PARA architecture.
