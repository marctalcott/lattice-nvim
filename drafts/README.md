# Send to GitHub — Drafts action

This Drafts action uploads the current draft as a Markdown capture to a private GitHub repository you choose each time. It archives the draft only after GitHub confirms the file exists. Lattice later fetches and files these captures (see [`specs/LATTICE_INBOX_SPEC.md`](../specs/LATTICE_INBOX_SPEC.md)), but the action works on its own.

## What it uploads

One file per draft, named from the draft's creation time and ID, for example `captures/2026-11-05-074500-3f1c9a52.md`:

```markdown
---
id: "3f1c9a52-7d0e-4b8a-9c11-5e2f0d7a4b6e"
created: "2026-11-05T07:45:00-05:00"
source: "drafts"
destination: "personal"
---
I was thinking about a better way to organize the project notes…
```

The text is sent exactly as written. The action adds no title, no summary and no task.

## 1. Create a capture repository for each destination

For each account (for example personal and work), create a **private** repository such as `lattice-inbox`, with at least one commit on the branch you will use (`main`). These are capture queues, not your notes repositories.

## 2. Create a token for each repository

On GitHub: **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**.

- **Resource owner:** the account or organization that owns the capture repository.
- **Repository access:** *Only select repositories*, choosing just that capture repository.
- **Permissions:** *Repository permissions → Contents: Read and write*. Nothing else.
- **Expiration:** your choice. When a token expires, the action reports the failure and asks for a new one on the next run; you don't need to change the action.

Organizations can require an administrator to approve fine-grained tokens, or require SAML SSO authorization. If uploads to the work repository fail with 403, check the token's status under the organization's settings.

Make one token per destination. Don't reuse the personal token for work.

## 3. Build the action in Drafts

Create a new action named **Send to GitHub**, with two steps in this order.

**Step 1: Define Template Tag**

- **Name:** `lattice_destinations`
- **Template:** your destinations as JSON. Each entry needs `name` (the button label), `id` (written into the capture as `destination`; lowercase letters, digits, `_` or `-`), `owner` and `repo`. `branch` defaults to `main` and `directory` to the repository root.

```json
{
  "destinations": [
    { "name": "Personal", "id": "personal", "owner": "personal-user", "repo": "lattice-inbox", "branch": "main", "directory": "captures" },
    { "name": "Work", "id": "work", "owner": "work-org", "repo": "lattice-inbox", "branch": "main", "directory": "captures" }
  ]
}
```

To add a destination later, add an entry here. The script doesn't change.

**Step 2: Script**

Paste the contents of [`send-to-github.js`](send-to-github.js).

**Action options:** set **After Success** to **Nothing**. The script archives the draft itself, and only after a confirmed upload.

## 4. First run

Run the action on a draft and choose a destination. The first time you choose each one, Drafts asks for its token and saves it in a credential named `Lattice <name>` (for example `Lattice Work`). Tokens are stored in Drafts' credential store, never in the action or in the uploaded file.

To replace a token, open **Drafts → Settings → Credentials**, forget `Lattice <name>`, and run the action again.

## Results

| What happened | Draft | Message |
|---|---|---|
| GitHub created the file | Archived | "Sent to Personal" |
| The file was already there from an earlier attempt (same draft ID) | Archived | "Sent to Personal" |
| A different capture already has that filename | Kept | Explains the collision |
| No network, timeout, or no response | Kept | Says to run the action again |
| 401: token rejected | Kept | The saved token is forgotten, so you're asked again next time |
| 403 or 404 | Kept | Points at permissions, SSO approval, or the owner, repo and branch |

Retrying is always safe. The filename depends only on the draft, and GitHub refuses to create a file that already exists. When it does, the action checks whether the existing file is this draft, and archives only if it is.

## Tests

The upload logic's pure parts are tested with Node's built-in test runner (no packages needed):

```sh
node drafts/test.js
```

The Drafts-specific parts (prompt, credentials, HTTP, archiving) need a manual check in Drafts: see the checklist in the pull request.
