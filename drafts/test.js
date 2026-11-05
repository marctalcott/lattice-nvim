// Tests for the pure helpers in send-to-github.js. Run: node drafts/test.js
// (Uses Node's built-in test runner; no packages needed.)
process.env.TZ = "America/New_York";

const test = require("node:test");
const assert = require("node:assert/strict");
const a = require("./send-to-github.js");

const UUID = "3F1C9A52-7D0E-4B8A-9C11-5E2F0D7A4B6E";
const ID = "3f1c9a52-7d0e-4b8a-9c11-5e2f0d7a4b6e";
const CREATED = new Date(2026, 10, 5, 7, 45, 0); // Nov 5 2026, 07:45 local

test("capture ID is the lowercased UUID; a missing UUID is an error", () => {
  assert.equal(a.captureId(UUID), ID);
  assert.throws(() => a.captureId(""), /valid UUID/);
  assert.throws(() => a.captureId("../etc"), /valid UUID/);
});

test("timestamp is local ISO 8601 with a colon offset", () => {
  assert.equal(a.isoLocal(CREATED), "2026-11-05T07:45:00-05:00");
  assert.equal(a.isoLocal(new Date(2026, 6, 1, 23, 5, 9)), "2026-07-01T23:05:09-04:00");
});

test("filename is sortable, Git-safe and stable for the same draft", () => {
  assert.equal(a.captureFilename(CREATED, ID), "2026-11-05-074500-3f1c9a52.md");
  assert.equal(a.captureFilename(CREATED, ID), a.captureFilename(new Date(CREATED), ID));
  assert.match(a.captureFilename(CREATED, ID), /^[\w.-]+$/);
});

test("markdown is front matter plus the text unchanged", () => {
  const text = "I was thinking about the Etna notes.\n\n  - keep this indent\nno trailing newline";
  const md = a.captureMarkdown(ID, CREATED, "personal", text);
  assert.equal(md,
    '---\nid: "' + ID + '"\ncreated: "2026-11-05T07:45:00-05:00"\nsource: "drafts"\ndestination: "personal"\n---\n' + text);
  assert.equal(a.frontMatterId(md), ID);
});

test("front matter id is read from captures, or null", () => {
  assert.equal(a.frontMatterId('---\nid: "abc"\n---\nbody'), "abc");
  assert.equal(a.frontMatterId("---\r\nid: abc\r\n---\r\nbody"), "abc");
  assert.equal(a.frontMatterId("no front matter\nid: abc"), null);
  assert.equal(a.frontMatterId('---\ncreated: "x"\n---\n'), null);
});

test("base64 matches Node for ASCII, accents, CJK and emoji", () => {
  for (const s of ["", "a", "ab", "abc", "Café — Kīlauea", "火山", "Lava 🌋 dome\n"]) {
    assert.equal(a.base64Utf8(s), Buffer.from(s, "utf8").toString("base64"), JSON.stringify(s));
  }
});

const VALID = JSON.stringify({
  destinations: [
    { name: "Personal", id: "personal", owner: "personal-user", repo: "lattice-inbox", branch: "main", directory: "captures/" },
    { name: "Work", id: "work", owner: "work-org", repo: "lattice-inbox" },
  ],
});

test("destinations: valid list with defaults", () => {
  const list = a.parseDestinations(VALID);
  assert.equal(list.length, 2);
  assert.equal(list[0].directory, "captures");
  assert.equal(list[1].branch, "main");
  assert.equal(list[1].directory, "");
});

test("destinations: useful errors", () => {
  const bad = (destinations) => () => a.parseDestinations(JSON.stringify({ destinations }));
  assert.throws(() => a.parseDestinations("{"), /not valid JSON/);
  assert.throws(bad([]), /non-empty/);
  assert.throws(bad([{ name: "Work", id: "work", owner: "o" }]), /Work.*"repo" is required/);
  assert.throws(bad([{ name: "W", id: "Work Org", owner: "o", repo: "r" }]), /"id" may use only/);
  assert.throws(bad([{ name: "W", id: "w", owner: "o/x", repo: "r" }]), /owner/);
  assert.throws(bad([{ name: "W", id: "w", owner: "o", repo: "r", directory: "a/../b" }]), /plain relative path/);
  assert.throws(bad([
    { name: "W", id: "w", owner: "o", repo: "r" },
    { name: "W", id: "x", owner: "o", repo: "r" },
  ]), /Two destinations/);
});

test("contents URL encodes each path segment", () => {
  const [personal, work] = a.parseDestinations(VALID);
  assert.equal(a.contentsUrl(personal, "f.md"),
    "https://api.github.com/repos/personal-user/lattice-inbox/contents/captures/f.md");
  assert.equal(a.contentsUrl(work, "f.md"),
    "https://api.github.com/repos/work-org/lattice-inbox/contents/f.md");
  assert.equal(a.contentsUrl({ owner: "o", repo: "r", directory: "my captures" }, "f.md"),
    "https://api.github.com/repos/o/r/contents/my%20captures/f.md");
});

const never = () => { throw new Error("should not fetch"); };

test("upload: 201 succeeds", () => {
  assert.equal(a.interpretUpload({ statusCode: 201 }, ID, never).ok, true);
});

test("upload: 422 with this capture already there succeeds (retry after uncertain outcome)", () => {
  const existing = { statusCode: 200, text: a.captureMarkdown(ID, CREATED, "personal", "x") };
  const r = a.interpretUpload({ statusCode: 422, text: '{"message":"\\"sha\\" wasn\'t supplied."}' }, ID, () => existing);
  assert.deepEqual([r.ok, r.message], [true, "already uploaded"]);
});

test("upload: 422 with a different capture fails and does not archive", () => {
  const existing = { statusCode: 200, text: '---\nid: "other"\n---\n' };
  const r = a.interpretUpload({ statusCode: 422 }, ID, () => existing);
  assert.equal(r.ok, false);
  assert.match(r.message, /different capture/);
});

test("upload: network failure fails with a retry hint", () => {
  const r = a.interpretUpload({ statusCode: 0, error: "The request timed out." }, ID, never);
  assert.equal(r.ok, false);
  assert.match(r.message, /timed out.*retry/);
});

test("upload: 401 forgets the credential; 403 and 404 explain", () => {
  const r401 = a.interpretUpload({ statusCode: 401, text: '{"message":"Bad credentials"}' }, ID, never);
  assert.equal(r401.forgetCredential, true);
  assert.match(r401.message, /401: Bad credentials/);
  const r403 = a.interpretUpload({ statusCode: 403, text: "" }, ID, never);
  assert.equal(r403.forgetCredential, false);
  assert.match(r403.message, /SSO/);
  assert.match(a.interpretUpload({ statusCode: 404 }, ID, never).message, /owner, repo and branch/);
});
