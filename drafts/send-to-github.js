// Lattice Inbox — "Send to GitHub" action for Drafts (iOS/macOS).
//
// Uploads the current draft as one Markdown capture file to a GitHub
// repository chosen at run time, then archives the draft only after GitHub
// confirms the file exists. See drafts/README.md for setup and
// specs/LATTICE_INBOX_SPEC.md (§3, §4, A1.13) for the contract.
//
// Destinations come from the template tag `lattice_destinations`, set by a
// "Define Template Tag" step placed before this script step. Tokens live in
// Drafts credentials, one per destination, never in this file.

var TAG = "lattice_destinations";
var API = "https://api.github.com";

// ---------------------------------------------------------------------------
// Pure helpers (no Drafts APIs; tested by drafts/test.js under Node)

function pad(n, width) {
  var s = String(n);
  while (s.length < (width || 2)) s = "0" + s;
  return s;
}

// The capture ID: the draft's UUID, lowercased.
function captureId(uuid) {
  var id = String(uuid || "").toLowerCase();
  if (!/^[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}$/.test(id)) {
    throw new Error("Draft has no valid UUID: " + uuid);
  }
  return id;
}

// ISO 8601 in local time with a ±HH:MM offset, e.g. 2026-11-05T07:45:00-05:00.
function isoLocal(date) {
  var offset = -date.getTimezoneOffset();
  var sign = offset >= 0 ? "+" : "-";
  offset = Math.abs(offset);
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) +
    "T" + pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds()) +
    sign + pad(Math.floor(offset / 60)) + ":" + pad(offset % 60);
}

// YYYY-MM-DD-HHMMSS-<first 8 hex of the UUID>.md, from the draft's creation
// time, so a retry always targets the same remote file.
function captureFilename(createdAt, id) {
  var d = createdAt;
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "-" +
    pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds()) + "-" +
    id.replace(/-/g, "").slice(0, 8) + ".md";
}

// Front matter plus the draft's text, unchanged.
function captureMarkdown(id, createdAt, destinationId, content) {
  return "---\n" +
    'id: "' + id + '"\n' +
    'created: "' + isoLocal(createdAt) + '"\n' +
    'source: "drafts"\n' +
    'destination: "' + destinationId + '"\n' +
    "---\n" +
    content;
}

// Reads `id` from a capture's front matter, or null.
function frontMatterId(text) {
  var m = /^---\r?\n([\s\S]*?)\r?\n---(\r?\n|$)/.exec(String(text || ""));
  if (!m) return null;
  var line = /^id:\s*"?([^"\r\n]*?)"?\s*$/m.exec(m[1]);
  return line ? line[1] : null;
}

// Validates the destinations JSON. Returns the list or throws with a message
// that names the problem.
function parseDestinations(json) {
  var data;
  try {
    data = JSON.parse(json);
  } catch (e) {
    throw new Error("The " + TAG + " template tag is not valid JSON: " + e.message);
  }
  var list = data && data.destinations;
  if (!Array.isArray(list) || list.length === 0) {
    throw new Error("The " + TAG + " template tag needs a non-empty \"destinations\" list.");
  }
  var seen = {};
  list.forEach(function (d, i) {
    var where = "Destination " + (i + 1) + (d && d.name ? " (" + d.name + ")" : "");
    if (!d || typeof d !== "object") throw new Error(where + " is not an object.");
    ["name", "id", "owner", "repo"].forEach(function (key) {
      if (typeof d[key] !== "string" || d[key].trim() === "") {
        throw new Error(where + ": \"" + key + "\" is required.");
      }
    });
    if (!/^[a-z0-9_-]+$/.test(d.id)) {
      throw new Error(where + ": \"id\" may use only a-z, 0-9, _ and -.");
    }
    if (!/^[A-Za-z0-9_.-]+$/.test(d.owner) || !/^[A-Za-z0-9_.-]+$/.test(d.repo)) {
      throw new Error(where + ": \"owner\" and \"repo\" must be a GitHub owner and repository name.");
    }
    d.branch = d.branch === undefined ? "main" : d.branch;
    d.directory = d.directory === undefined ? "" : d.directory;
    if (typeof d.branch !== "string" || d.branch === "") throw new Error(where + ": \"branch\" must be a non-empty string.");
    if (typeof d.directory !== "string") throw new Error(where + ": \"directory\" must be a string.");
    d.directory = d.directory.replace(/^\/+|\/+$/g, "");
    if (d.directory.split("/").some(function (part) { return part === ".." || part === "."; }) ||
        /\/\//.test(d.directory)) {
      throw new Error(where + ": \"directory\" must be a plain relative path.");
    }
    if (seen[d.name]) throw new Error("Two destinations are named \"" + d.name + "\".");
    seen[d.name] = true;
  });
  return list;
}

// REST URL for a file in the destination; each path segment is encoded.
function contentsUrl(dest, filename) {
  var parts = (dest.directory ? dest.directory.split("/") : []).concat([filename]);
  return API + "/repos/" + encodeURIComponent(dest.owner) + "/" + encodeURIComponent(dest.repo) +
    "/contents/" + parts.map(encodeURIComponent).join("/");
}

// Base64 of a string's UTF-8 bytes (GitHub's contents API expects base64).
function base64Utf8(text) {
  var bytes = [];
  for (var i = 0; i < text.length; i++) {
    var c = text.codePointAt(i);
    if (c > 0xffff) i++;
    if (c < 0x80) bytes.push(c);
    else if (c < 0x800) bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else bytes.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  var out = "";
  for (var j = 0; j < bytes.length; j += 3) {
    var n = (bytes[j] << 16) | ((bytes[j + 1] || 0) << 8) | (bytes[j + 2] || 0);
    out += chars[(n >> 18) & 63] + chars[(n >> 12) & 63] +
      (j + 1 < bytes.length ? chars[(n >> 6) & 63] : "=") +
      (j + 2 < bytes.length ? chars[n & 63] : "=");
  }
  return out;
}

// GitHub's error message from a response body, without echoing anything else.
function githubMessage(body) {
  try {
    var m = JSON.parse(body).message;
    if (typeof m === "string") return m;
  } catch (e) { /* not JSON */ }
  return "";
}

// Decides what an upload's outcome means. `put` is the PUT response;
// `getExisting` fetches the remote file's raw text when the PUT reports that a
// file already exists. Returns { ok, message, forgetCredential }.
function interpretUpload(put, id, getExisting) {
  if (put.statusCode === 201) return { ok: true, message: "created" };
  if (put.statusCode === 422) {
    var existing = getExisting();
    if (existing.statusCode === 200) {
      if (frontMatterId(existing.text) === id) {
        return { ok: true, message: "already uploaded" };
      }
      return { ok: false, message: "A different capture already uses this filename. The draft was not archived." };
    }
    return { ok: false, message: "GitHub refused the file (422): " + githubMessage(put.text) };
  }
  if (!put.statusCode) {
    return { ok: false, message: "No response from GitHub" + (put.error ? " (" + put.error + ")" : "") +
      ". The draft was not archived; run the action again to retry." };
  }
  var detail = githubMessage(put.text);
  var hint = "";
  if (put.statusCode === 401) hint = " The token was rejected; you'll be asked for a new one next time.";
  else if (put.statusCode === 403) hint = " The token may lack Contents write access, or the organization requires approving it or authorizing SSO.";
  else if (put.statusCode === 404) hint = " Check owner, repo and branch, and that the token can see the repository.";
  return {
    ok: false,
    forgetCredential: put.statusCode === 401,
    message: "GitHub returned " + put.statusCode + (detail ? ": " + detail : "") + "." + hint + " The draft was not archived.",
  };
}

// ---------------------------------------------------------------------------
// Drafts runtime

function readDestinations() {
  var raw = draft.getTemplateTag(TAG);
  if (!raw) {
    throw new Error("No destinations: add a \"Define Template Tag\" step named " + TAG + " before the script step.");
  }
  return parseDestinations(raw);
}

function chooseDestination(list) {
  var p = Prompt.create();
  p.title = "Send to GitHub";
  p.message = "Choose where this capture goes.";
  list.forEach(function (d) { p.addButton(d.name); });
  if (!p.show()) return null;
  for (var i = 0; i < list.length; i++) {
    if (list[i].name === p.buttonPressed) return list[i];
  }
  return null;
}

function tokenFor(dest) {
  var credential = Credential.create("Lattice " + dest.name,
    "A fine-grained GitHub token for " + dest.owner + "/" + dest.repo + " with Contents: read and write.");
  credential.addPasswordField("token", "GitHub token");
  if (!credential.authorize()) return null;
  return { credential: credential, token: credential.getValue("token") };
}

function request(method, url, token, data, accept) {
  var http = HTTP.create();
  http.timeout = 30;
  var options = {
    url: url,
    method: method,
    headers: {
      "Authorization": "Bearer " + token,
      "Accept": accept || "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  };
  if (data) {
    options.data = data;
    options.encoding = "json";
  }
  var r = http.request(options);
  return { statusCode: r.statusCode, text: r.responseText, error: r.error };
}

function main() {
  if (draft.content.trim() === "") {
    app.displayWarningMessage("The draft is empty; nothing was sent.");
    context.cancel();
    return;
  }
  var destinations = readDestinations();
  var dest = chooseDestination(destinations);
  if (!dest) {
    context.cancel();
    return;
  }
  var auth = tokenFor(dest);
  if (!auth || !auth.token) {
    context.cancel("No token for " + dest.name + ".");
    return;
  }

  var id = captureId(draft.uuid);
  var filename = captureFilename(draft.createdAt, id);
  var url = contentsUrl(dest, filename);
  var body = captureMarkdown(id, draft.createdAt, dest.id, draft.content);

  var put = request("PUT", url, auth.token, {
    message: "Capture " + filename,
    content: base64Utf8(body),
    branch: dest.branch,
  });
  var outcome = interpretUpload(put, id, function () {
    return request("GET", url + "?ref=" + encodeURIComponent(dest.branch), auth.token, null,
      "application/vnd.github.raw+json");
  });

  if (!outcome.ok) {
    if (outcome.forgetCredential) auth.credential.forget();
    app.displayErrorMessage("Not sent to " + dest.name);
    context.fail(outcome.message);
    alert(outcome.message);
    return;
  }
  draft.isArchived = true;
  draft.update();
  app.displaySuccessMessage("Sent to " + dest.name);
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    captureId: captureId,
    isoLocal: isoLocal,
    captureFilename: captureFilename,
    captureMarkdown: captureMarkdown,
    frontMatterId: frontMatterId,
    parseDestinations: parseDestinations,
    contentsUrl: contentsUrl,
    base64Utf8: base64Utf8,
    interpretUpload: interpretUpload,
  };
} else {
  try {
    main();
  } catch (e) {
    app.displayErrorMessage("Send to GitHub failed");
    context.fail(e.message);
    alert(e.message);
  }
}
