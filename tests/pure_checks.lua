--[[--
Checks for the plugin's pure functions: URL building, OPDS 2.0 mapping,
annotation mapping, and the kosync settings patch.

Runs under plain `lua` or `luajit` — no KOReader, no network. The few
KOReader modules `coppice_kosync` pulls in are stubbed below; the three genuinely
pure modules (`coppice_url`, `coppice_opds`, `coppice_annotations`) need no stubs at
all, which is why they are shaped that way.

    lua tests/pure_checks.lua
    luajit tests/pure_checks.lua

A real device run is a different thing and this does not substitute for it:
every rule asserted here about the *server* is the server's rule, taken from
Coppice's own source, and is verified separately with curl against a live Coppice.
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../coppice.koplugin/?.lua;" .. here .. "/fixtures/?.lua;" .. package.path

-- ------------------------------------------------------------------ stubs

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp/coppice-test-settings" end }
end
package.preload["luasettings"] = function()
    local LuaSettings = {}
    LuaSettings.__index = LuaSettings
    function LuaSettings:open() return setmetatable({ data = {} }, LuaSettings) end
    function LuaSettings:readSetting(key, default)
        if self.data[key] == nil then self.data[key] = default end
        return self.data[key]
    end
    function LuaSettings:saveSetting(key, value) self.data[key] = value end
    function LuaSettings:flush() end
    return LuaSettings
end
package.preload["ffi/sha2"] = function()
    -- Not MD5: a deterministic 32-hex stand-in, which is all these checks
    -- need (they assert determinism and length, never a specific digest).
    return {
        md5 = function(input)
            local hash = 5381
            for index = 1, #input do
                hash = (hash * 33 + input:byte(index)) % 0xFFFFFFFF
            end
            return string.format("%08x%08x%08x%08x", hash,
                (hash * 7) % 0xFFFFFFFF, (hash * 13) % 0xFFFFFFFF,
                (hash * 31) % 0xFFFFFFFF)
        end,
    }
end

local Url = require("coppice_url")
local Opds = require("coppice_opds")
local Annotations = require("coppice_annotations")
local AnnotationSync = require("coppice_annotation_sync")
local KoSync = require("coppice_kosync")
local Settings = require("coppice_settings")
local Errors = require("coppice_errors")
local Catalog = require("coppice_catalog")

-- ---------------------------------------------------------------- harness

local passed, failed = 0, 0
local current

local function group(name) current = name end

local function ok(condition, label)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("FAIL  %s: %s\n", current, label))
    end
end

local function eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("FAIL  %s: %s\n        expected %s\n        got      %s\n",
            current, label, tostring(expected), tostring(actual)))
    end
end

-- ------------------------------------------------------------------ URLs

group("Url.normalizeBase")
eq(Url.normalizeBase("http://host:10801"), "http://host:10801", "plain base")
eq(Url.normalizeBase("http://host:10801/"), "http://host:10801", "trailing slash")
eq(Url.normalizeBase("  https://books.example.com///  "), "https://books.example.com",
    "whitespace and repeated slashes")
eq(Url.normalizeBase("http://host/opds/v2.0/catalog"), "http://host",
    "pasted OPDS 2.0 catalogue")
eq(Url.normalizeBase("http://host/opds/v1.2/catalog"), "http://host",
    "pasted OPDS 1.2 catalogue")
eq(Url.normalizeBase("http://host/koreader/coppice_abc123"), "http://host",
    "pasted kosync endpoint")
eq(Url.normalizeBase("http://host/api/v2/health"), "http://host", "pasted API path")
eq(Url.normalizeBase("host:10801"), nil, "a bare host is not guessed")
eq(Url.normalizeBase("ftp://host"), nil, "non-http scheme rejected")
eq(Url.normalizeBase("http://"), nil, "scheme with no host rejected")
eq(Url.normalizeBase(""), nil, "empty rejected")
eq(Url.normalizeBase(nil), nil, "nil rejected")
eq(Url.normalizeBase("https://user:pass@host"), nil, "userinfo is rejected")
eq(Url.normalizeBase("https://host?token=secret"), nil, "query parameters are rejected")
eq(Url.normalizeBase("https://host/#fragment"), nil, "fragments are rejected")
eq(Url.normalizeBase("http://host/a/../b"), nil, "dot-segment paths are rejected")
eq(Url.normalizeBase("http://host:99999"), nil, "out-of-range ports are rejected")

group("Settings.validate")
local validated = Settings.validate({
    server = "https://user:secret@host",
    username = "  alice  ",
    api_key = "api-secret\n",
    liseur_secret = "liseur-token",
    device_id = "unsafe\nid",
    pairing_code = "123456\n",
    pairing_nonce = "safe_nonce",
    pairing_poll_interval = "0",
    download_dir = "/books",
    unrelated = "not persisted",
}, {
    server = "http://valid.example",
    device_name = "  Kobo  ",
    api_key = "must-not-be-imported",
})
eq(validated.server, "http://valid.example", "invalid saved address falls back to config")
eq(validated.username, "alice", "labels are trimmed")
eq(validated.api_key, nil, "credential controls are rejected")
eq(validated.liseur_secret, "liseur-token", "safe credential is retained")
eq(validated.device_id, nil, "control characters are rejected in identifiers")
eq(validated.pairing_code, nil, "pairing code must be six digits")
eq(validated.pairing_nonce, "safe_nonce", "safe pending nonce is retained")
eq(validated.pairing_poll_interval, nil, "poll interval rejects values below one second")
eq(validated.download_dir, "/books", "saved download directory is retained")
eq(validated.device_name, "Kobo", "safe display name falls back from config")
eq(validated.unrelated, nil, "unknown persisted settings are discarded")
eq(Settings.credential(string.rep("x", 4097)), nil, "oversized secrets are rejected")
eq(validated.open_on_start, true, "opening at startup defaults on for older settings")
eq(Settings.validate({ open_on_start = false }).open_on_start, false,
    "turning startup opening off persists")

group("Errors.describe")
local auth_error = Errors.describe("401 secret=never-display", 401)
eq(auth_error, "Coppice rejected this device credential. Pair the device again.",
    "HTTP auth errors map to a safe summary")
ok(not auth_error:find("secret", 1, true), "response detail is not shown")
eq(Errors.describe("server timed out at private.example"), 
    "The request timed out. Check the connection and try again.",
    "timeout errors are classified")
eq(Errors.describe(nil, 503),
    "Coppice is temporarily unavailable. Try again later.",
    "server failures are classified")


group("Url.query")
eq(Url.query({ b = 2, a = 1 }), "a=1&b=2", "keys are sorted, so URLs are stable")
eq(Url.query({ query = "a b&c=d" }), "query=a%20b%26c%3Dd", "reserved characters escaped")
eq(Url.query({ page = 1, page_size = false, limit = nil }), "page=1",
    "false and nil values are dropped")
eq(Url.query({}), "", "empty table is no query")
eq(Url.query(nil), "", "nil is no query")

group("Url.escape")
eq(Url.escape("a-b_c.d~e"), "a-b_c.d~e", "unreserved characters pass through")
eq(Url.escape("/"), "%2F", "path separator escaped")
eq(Url.escape("ä"), "%C3%A4", "multi-byte UTF-8 escaped per byte")

group("Url.rebase")
eq(Url.rebase("http://192.168.1.10:10801", "http://proxy.example/opds/v2.0/books/1"),
    "http://192.168.1.10:10801/opds/v2.0/books/1",
    "a foreign origin is replaced by the configured one")
eq(Url.rebase("http://host", "/opds/v2.0/x"), "http://host/opds/v2.0/x",
    "root-relative href")
eq(Url.rebase("http://host", "opds/x"), "http://host/opds/x", "relative href")
eq(Url.rebase("http://host", "https://other:8443"), "http://host/",
    "origin-only href keeps a root path")
eq(Url.rebase("http://host", ""), nil, "empty href")
eq(Url.rebase("http://host", "javascript:alert(1)"), nil,
    "unsupported schemes are rejected")

group("Url.sameOrigin")
eq(Url.sameOrigin("https://host", "https://HOST/path"), true,
    "host casing follows URL origin semantics")
eq(Url.sameOrigin("https://host", "https://evil/path"), false,
    "foreign request origins are rejected")
eq(Url.sameOrigin("https://host", "javascript:alert(1)"), false,
    "non-HTTP request schemes are rejected")
eq(Url.rebase(nil, "/x"), nil, "no base")

group("Url route builders")
eq(Url.opds("http://h", "/catalog"), "http://h/opds/v2.0/catalog", "OPDS root")
eq(Url.opds("http://h", "/search", { query = "x" }),
    "http://h/opds/v2.0/search?query=x", "OPDS with query")
eq(Url.api("http://h", "/reading/continue", { limit = 5 }),
    "http://h/api/v2/reading/continue?limit=5", "continue-reading route")
eq(Url.api("http://h", "/media/abc/file"), "http://h/api/v2/media/abc/file",
    "download route")
eq(Url.liseur("http://h", "/annotations"), "http://h/v1/annotations",
    "annotation route")
eq(Url.kosync("http://h", "coppice_K"), "http://h/koreader/coppice_K",
    "kosync base is what the built-in client wants")
eq(Url.kosyncAuth("http://h", "coppice_K"), "http://h/koreader/coppice_K/users/auth",
    "kosync auth route")
eq(Url.kosyncPutProgress("http://h", "coppice_K"),
    "http://h/koreader/coppice_K/syncs/progress", "kosync push route")
eq(Url.kosyncGetProgress("http://h", "coppice_K", "deadbeef"),
    "http://h/koreader/coppice_K/syncs/progress/deadbeef", "kosync pull route")
eq(Url.kosync("http://h", nil), nil, "no key, no kosync URL")
eq(Url.kosync("http://h", "key/a?b"), "http://h/koreader/key%2Fa%3Fb",
    "kosync credential cannot add path or query components")
eq(Url.kosyncGetProgress("http://h", "coppice_K", ""), nil, "no document, no pull URL")

-- ------------------------------------------------------------- OPDS 2.0

group("Opds.extensionForType")
eq(Opds.extensionForType("application/epub+zip"), "epub", "epub")
eq(Opds.extensionForType("application/vnd.comicbook+zip"), "cbz", "cbz")
eq(Opds.extensionForType("application/pdf"), "pdf", "pdf")
eq(Opds.extensionForType("application/epub+zip; charset=utf-8"), "epub",
    "media-type parameters ignored")
eq(Opds.extensionForType("audio/mp4"), nil,
    "an audiobook is not given a reader extension")
eq(Opds.extensionForType(nil), nil, "nil type")

group("Opds.bookId")
eq(Opds.bookId("http://h/opds/v2.0/books/abc-123"), "abc-123", "from an OPDS self link")
eq(Opds.bookId("http://h/opds/v2.0/books/abc-123/file"), "abc-123",
    "from an acquisition link")
eq(Opds.bookId("http://h/api/v2/media/xyz/audio/track/0"), "xyz",
    "from an audio track link")
eq(Opds.bookId("http://h/opds/v2.0/series/s1"), nil, "a series href is not a book")

group("Opds.publication")
local single = Opds.publication("http://base", {
    metadata = {
        title = "Ender's Game",
        author = { { name = "Orson Scott Card" } },
        belongsTo = { series = { name = "Ender", position = 1 } },
    },
    links = {
        { rel = "self", type = "application/divina+json",
          href = "http://proxy/opds/v2.0/books/bk1" },
        { rel = "http://opds-spec.org/acquisition", type = "application/epub+zip",
          href = "http://proxy/opds/v2.0/books/bk1/file" },
        { rel = "http://www.cantook.com/api/progression",
          type = "application/vnd.readium.progression+json",
          href = "http://proxy/opds/v2.0/books/bk1/progression" },
    },
})
eq(single.id, "bk1", "id from the self link")
eq(single.title, "Ender's Game", "title")
eq(single.author, "Orson Scott Card", "author list flattened")
eq(single.series, "Ender", "series name from belongsTo")
eq(single.series_position, 1, "series position")
eq(single.extension, "epub", "extension from the acquisition media type")
eq(single.download_url, "http://base/opds/v2.0/books/bk1/file",
    "acquisition href re-based onto the configured server")
eq(single.progression_url, "http://base/opds/v2.0/books/bk1/progression",
    "progression is a link, not a value — this is why the dashboard uses /api/v2")
eq(single.track_count, nil, "a single-file book has no track count")

local multi = Opds.publication("http://base", {
    metadata = { title = "Audiobook" },
    links = {
        { rel = "self", href = "http://base/opds/v2.0/books/ab1" },
        { rel = "http://opds-spec.org/acquisition", type = "audio/mpeg",
          href = "http://base/api/v2/media/ab1/audio/track/0" },
        { rel = "http://opds-spec.org/acquisition", type = "audio/mpeg",
          href = "http://base/api/v2/media/ab1/audio/track/1" },
    },
})
eq(multi.track_count, 2, "multi-track audiobook reports its track count")
eq(multi.download_url, nil, "a playlist is not a downloadable single file")

local rel_array = Opds.publication("http://base", {
    metadata = { title = "Array rel" },
    links = {
        { rel = { "self", "alternate" }, href = "http://base/opds/v2.0/books/ar1" },
        { rel = { "http://opds-spec.org/acquisition" }, type = "application/pdf",
          href = "http://base/opds/v2.0/books/ar1/file" },
    },
})
eq(rel_array.id, "ar1", "rel given as an array is still matched")
eq(rel_array.extension, "pdf", "acquisition found through an array rel")

group("Opds.feed")
local view = Opds.feed("http://base", {
    metadata = { title = "Coppice OPDS V2 Catalog" },
    groups = {
        {
            metadata = { title = "Libraries" },
            links = { { rel = "self", href = "http://base/opds/v2.0/libraries" } },
            navigation = {
                { title = "Books", href = "http://proxy/opds/v2.0/libraries/l1" },
            },
        },
        {
            metadata = { title = "Keep Reading" },
            publications = {
                {
                    metadata = { title = "In progress" },
                    links = {
                        { rel = "self", href = "http://base/opds/v2.0/books/kr1" },
                        { rel = "http://opds-spec.org/acquisition",
                          type = "application/epub+zip",
                          href = "http://base/opds/v2.0/books/kr1/file" },
                    },
                },
            },
        },
    },
    links = {
        { rel = "self", href = "http://base/opds/v2.0/catalog" },
        { rel = "next", href = "http://base/opds/v2.0/catalog?page=2" },
    },
})
eq(view.title, "Coppice OPDS V2 Catalog", "feed title")
eq(#view.groups, 2, "both groups mapped")
eq(view.groups[1].navigation[1].url, "http://base/opds/v2.0/libraries/l1",
    "group navigation is re-based too")
eq(view.groups[2].publications[1].id, "kr1", "group publications mapped")
eq(view.paging.next_url, "http://base/opds/v2.0/catalog?page=2", "next page link")
eq(#view.publications, 0, "root feed has no top-level publications")

group("Opds.filename")
eq(Opds.filename({ title = "A/B: C?", id = "abcdef123456", extension = "epub" }),
    "A_B_ C_-abcdef12.epub", "FAT32-illegal characters replaced, id suffix, extension")
eq(Opds.filename({ title = "  spaced   out  ", id = "ident", extension = "cbz" }),
    "spaced out-ident.cbz", "whitespace collapsed and trimmed")
ok(#Opds.filename({ title = string.rep("x", 400), id = "i", extension = "epub" }) <= 112,
    "long titles are bounded")
eq(Opds.filename({ title = "", id = "i" }), "book-i", "empty title falls back")

-- ----------------------------------------------------------- annotations

group("Annotations.kind")
eq(Annotations.kind({ drawer = "lighten", page = "/body/x" }), "highlight",
    "a drawn annotation is a highlight")
eq(Annotations.kind({ page = "/body/x" }), "bookmark",
    "no drawer means a page bookmark")

group("Annotations.color")
for _, color in ipairs({
    "yellow", "green", "blue", "pink", "purple", "orange",
    "red", "olive", "cyan", "gray",
}) do
    eq(Annotations.color(color), color, color .. " round-trips exactly")
end
eq(Annotations.color("Purple"), "purple", "palette lookup is case-insensitive")
eq(Annotations.color("magenta"), nil, "unknown color is rejected, not guessed")
eq(Annotations.drawer("underscore"), "underline", "KOReader underscore uses wire underline")
eq(Annotations.nativeDrawer("underline"), "underscore", "wire underline restores KOReader drawer")
eq(Annotations.drawer("blended"), nil, "unknown style is rejected")
group("Annotations.clip")
eq(Annotations.clip("abc", 10), "abc", "under budget")
eq(Annotations.clip("abcdef", 3), "abc", "clipped to budget")
eq(Annotations.clip("", 10), nil, "empty is absent")
eq(Annotations.clip(nil, 10), nil, "nil is absent")
local clipped = Annotations.clip("aä", 2)
eq(clipped, "a", "never splits a UTF-8 sequence")
ok(#Annotations.clip(string.rep("ä", 20), 5) <= 5, "multi-byte clip respects the budget")

group("Annotations.clientTs")
eq(Annotations.clientTs("2026-03-04 05:06:07"):match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$")
    ~= nil, true, "RFC 3339 UTC, which is what the server parses")
eq(Annotations.clientTs("not a date", 0), "1970-01-01T00:00:00Z",
    "unparseable datetime falls back to the supplied now")
eq(Annotations.clientTs(nil, 0), "1970-01-01T00:00:00Z", "missing datetime falls back")
eq(Annotations.clientTs("2026-09-24T18:39:32.820164765+00:00", 0), "2026-09-24T18:39:32Z",
    "server stamps with a fraction and +00:00 stay the same UTC instant")
eq(Annotations.clientTs("2026-09-24T20:39:32+02:00", 0), "2026-09-24T18:39:32Z",
    "a positive offset converts to UTC")
eq(Annotations.clientTs("2026-09-24T18:39:32Z", 0), "2026-09-24T18:39:32Z", "plain UTC passes through")
-- KOReader writes local wall-clock time; the UTC instant must be exact in
-- both standard and daylight-saving time (a summer highlight used to be sent
-- an hour late in CEST).
for _unused, instant in ipairs({
    os.time({ year = 2026, month = 1, day = 15, hour = 12, min = 0, sec = 0 }),
    os.time({ year = 2026, month = 7, day = 15, hour = 12, min = 0, sec = 0 }),
}) do
    eq(Annotations.clientTs(os.date("%Y-%m-%d %H:%M:%S", instant)),
        os.date("!%Y-%m-%dT%H:%M:%SZ", instant),
        "local time converts to the exact UTC instant (" .. os.date("%B", instant) .. ")")
end

eq(Annotations.timestampAfter(
    "2026-01-01T12:00:00Z",
    "2026-01-01T12:00:00.000000000Z"),
    false, "RFC 3339 nanosecond timestamp compares as the same instant")
eq(Annotations.timestampAfter(
    "2026-01-01T12:00:00Z",
    "2026-01-01T14:00:00+02:00"),
    false, "timezone offsets compare as UTC instants")
eq(Annotations.timestampAfter(
    "2026-01-01T12:00:00.000000001Z",
    "2026-01-01T12:00:00Z"),
    true, "subsecond local edit is newer than the server timestamp")
eq(Annotations.timestampAfter(
    "not-a-time", "2026-01-01T11:00:00Z"),
    false, "invalid conflict timestamps are not guessed")

group("Annotations.progression")
eq(Annotations.progression({ pageno = 50 }, 200), 0.25, "pageno over page count")
eq(Annotations.progression({ pageno = 500 }, 200), 1, "clamped at 1")
eq(Annotations.progression({ pageno = 10 }, 0), nil, "no page count, no progression")
eq(Annotations.progression({}, 200), nil, "no pageno, no progression")

group("Annotations.id")
local digest = require("ffi/sha2").md5
local item_a = { datetime = "2026-01-01 10:00:00", page = "/body/p[1]",
                 pos0 = "/body/p[1].0", pos1 = "/body/p[1].20", pageno = 3 }
local item_b = { datetime = "2026-01-01 10:00:00", page = "/body/p[1]",
                 pos0 = "/body/p[1].0", pos1 = "/body/p[1].40", pageno = 3 }
eq(Annotations.id(item_a, "doc", digest), Annotations.id(item_a, "doc", digest),
    "same anchor, same id — a re-push must hit the same record, never create a second")
ok(Annotations.id(item_a, "doc", digest) ~= Annotations.id(item_b, "doc", digest),
    "a different end anchor is a different annotation")
ok(Annotations.id(item_a, "doc", digest) ~= Annotations.id(item_a, "other", digest),
    "the same anchor in another document is another annotation")
ok(#Annotations.id(item_a, "doc", digest) <= Annotations.MAX_ID_BYTES,
    "id stays inside the server's 64-byte bound")
eq(Annotations.id(item_a, "doc", nil), nil, "no digest, no id")

group("Annotations.one")
local highlight = Annotations.one({
    datetime = "2026-01-01 10:00:00",
    drawer = "lighten",
    color = "yellow",
    text = "the selected passage",
    note = "my thought about it",
    chapter = "Chapter 3",
    pageno = 40,
    page = "/body/DocFragment[3]/body/div/p[10]/text()[1].0",
    pos0 = "/body/DocFragment[3]/body/div/p[10]/text()[1].0",
    pos1 = "/body/DocFragment[3]/body/div/p[10]/text()[1].25",
}, { work_id = "w1", document_hash = "d1", page_count = 200, digest = digest })
eq(highlight.kind, "highlight", "highlight kind")
eq(highlight.excerpt, "the selected passage", "the passage becomes excerpt")
eq(highlight.body, "my thought about it", "the user's note becomes body")
eq(highlight.color, "yellow", "colour kept on a highlight")
eq(highlight.work_id, "w1", "work id carried")
eq(highlight.base_rev, 0, "unknown revision creates")
eq(highlight.progression, 0.2, "progression from pageno/page count")
eq(highlight.locator.format, "koreader-annotation", "locator is tagged reader-native")
eq(highlight.locator.pos1,
    "/body/DocFragment[3]/body/div/p[10]/text()[1].25",
    "the x-pointer travels verbatim, never converted to a Readium locator")
eq(highlight.locator.document, "d1", "locator names the document it anchors to")
eq(highlight.locator.pboxes, nil, "render boxes are not identity and are dropped")

local bookmark = Annotations.one({
    datetime = "2026-01-01 11:00:00",
    page = "/body/DocFragment[1]/body/div/p[2]/text()[1].0",
    pageno = 5,
}, { work_id = "w1", document_hash = "d1", page_count = 100, digest = digest })
eq(bookmark.kind, "bookmark", "no drawer and no note means bookmark")
eq(bookmark.body, nil, "a bookmark carries no body")
eq(bookmark.color, "", "non-highlight mapping explicitly clears color")
eq(bookmark.drawer, "", "non-highlight mapping explicitly clears style")
ok(bookmark.locator ~= nil, "a bookmark still needs its locator")

local note = Annotations.one({
    datetime = "2026-01-01 11:30:00",
    page = "/body/DocFragment[1]/body/div/p[3]/text()[1].0",
    note = "a standalone annotation note",
}, { work_id = "w1", document_hash = "d1", digest = digest })
eq(note.kind, "note", "an annotation note maps to note kind")
eq(note.body, "a standalone annotation note", "note body is preserved")
ok(note.locator ~= nil, "an anchored KOReader note keeps its locator")

local paged = Annotations.one({
    datetime = "2026-01-01 12:00:00",
    drawer = "underscore",
    page = 42,
    pos0 = { x = 10, y = 20, page = 42 },
    pos1 = { x = 90, y = 40, page = 42 },
    pageno = 42,
}, { work_id = "w1", document_hash = "d1", page_count = 100, digest = digest })
eq(paged.locator.page, 42, "a paged document keeps its numeric page")
eq(paged.locator.pos0.x, 10, "paged positions travel as tables")
eq(paged.kind, "highlight", "paged highlight")
eq(paged.drawer, "underline", "underscore style maps to the wire underline token")

local no_color = Annotations.one({
    datetime = "2026-01-01 13:00:00", drawer = "lighten", color = "red",
    page = "/body/p[1]", pos0 = "/body/p[1].0",
}, { work_id = "w1", digest = digest })
eq(no_color.color, "red", "KOReader red is preserved")

group("Annotations round trip")
local native_locator = {
    format = "koreader-annotation",
    version = 1,
    document = "d1",
    page = "/body/p[4]/text()[1].0",
    pos0 = "/body/p[4]/text()[1].0",
    pos1 = "/body/p[4]/text()[1].12",
    pageno = 9,
}
local colors = {
    "yellow", "green", "blue", "pink", "purple", "orange",
    "red", "olive", "cyan", "gray",
}
for _, color in ipairs(colors) do
    local record = {
        id = "remote-" .. color,
        work_id = "w1",
        kind = "highlight",
        locator = native_locator,
        excerpt = "the imported words",
        body = "a preserved thought",
        color = color,
        drawer = "strikeout",
        client_ts = "2026-01-01T10:00:00Z",
        rev = 1,
    }
    local imported = Annotations.fromRemote(record)
    eq(imported.color, color, color .. " imports without loss")
    eq(imported.drawer, "strikeout", color .. " preserves highlight style")
    local exported = Annotations.one(imported, {
        work_id = "w1", document_hash = "d1", digest = digest,
    })
    eq(exported.color, color, color .. " re-exports without loss")
    eq(exported.drawer, "strikeout", color .. " re-exports style")
end
for wire, native in pairs({
    lighten = "lighten",
    underline = "underscore",
    strikeout = "strikeout",
    invert = "invert",
}) do
    local imported = Annotations.fromRemote({
        id = "style-" .. wire, kind = "highlight",
        locator = native_locator, drawer = wire,
        client_ts = "2026-01-01T10:00:00Z",
    })
    eq(imported.drawer, native, wire .. " restores KOReader drawer")
    local exported = Annotations.one(imported, {
        work_id = "w1", document_hash = "d1", digest = digest,
    })
    eq(exported.drawer, wire, wire .. " re-exports exactly")
end
local remote_note = Annotations.fromRemote({
    id = "remote-note", kind = "note", locator = native_locator,
    body = "a remote note", client_ts = "2026-01-01T10:00:00Z",
})
eq(remote_note.note, "a remote note", "server note body maps back to KOReader")
eq(Annotations.fromRemote({
    id = "bad-color", kind = "highlight", locator = native_locator,
    color = "magenta",
}), nil, "unsupported server color is not silently dropped")
local invalid_highlight, invalid_color_reason = Annotations.one({
    datetime = "2026-01-01 13:00:00", drawer = "lighten", color = "magenta",
    page = "/body/p[1]", pos0 = "/body/p[1].0",
}, { work_id = "w1", digest = digest })
eq(invalid_highlight, nil, "unsupported KOReader color is not sent partially")
eq(invalid_color_reason, "unsupported-color", "unsupported color is explicit")
eq(Annotations.one({ datetime = "2026-01-01 10:00:00" },
    { work_id = "w1", digest = digest }), nil, "no anchor, no annotation")
local _unused, reason = Annotations.one({ datetime = "x" },
    { work_id = "w1", digest = digest })
eq(reason, "no-anchor", "and the reason is reported")
eq(Annotations.one({ page = "/body/p" }, { digest = digest }), nil,
    "no work id, no annotation")
group("Annotations remote anchoring")
local readium_locator = {
    href = "OPS/chapter-one.xhtml",
    chapter = "Chapter One",
    text = { before = "in this chapter", after = "which follows" },
}
local candidates = {
    {
        href = "OPS/chapter-one.xhtml", chapter = "Chapter One",
        text = "Unique highlighted phrase",
        before = "Opening in this chapter", after = "which follows later",
        start = "xptr-unique-start", finish = "xptr-unique-end",
    },
    {
        href = "OPS/chapter-one.xhtml", chapter = "Chapter One",
        text = "Unique highlighted phrase",
        before = "different context", after = "which follows later",
        start = "xptr-wrong-context", finish = "xptr-wrong-end",
    },
    {
        href = "OPS/chapter-two.xhtml", chapter = "Chapter Two",
        text = "Unique highlighted phrase",
        before = "Opening in this chapter", after = "which follows later",
        start = "xptr-wrong-href", finish = "xptr-wrong-href-end",
    },
}
local anchored, anchor_error = Annotations.anchorCandidates(candidates,
    readium_locator, "  Unique   highlighted phrase ")
eq(anchor_error, nil, "matching excerpt/context/href yields one candidate")
eq(anchored.start, "xptr-unique-start", "the unique scoped hit is selected")
local ambiguous, ambiguous_error = Annotations.anchorCandidates({
    candidates[1],
    {
        href = "OPS/chapter-one.xhtml", chapter = "Chapter One",
        text = "Unique highlighted phrase",
        before = "Opening in this chapter", after = "which follows later",
        start = "xptr-second-match", finish = "xptr-second-end",
    },
}, { href = "OPS/chapter-one.xhtml", chapter = "Chapter One" },
    "Unique highlighted phrase")
eq(ambiguous, nil, "two text hits are not guessed")
eq(ambiguous_error, "ambiguous", "ambiguous locator is surfaced")
local unanchored, missing_error = Annotations.anchorCandidates(candidates,
    { href = "OPS/chapter-one.xhtml" }, "excerpt not in this chapter")
eq(unanchored, nil, "missing remote excerpt remains unanchored")
eq(missing_error, "not-found", "failed search has a precise reason")

do
-- Home-native Readium locator (The Lottery): KOReader hits carry no href,
-- only five words of context, and different punctuation than the locator.
local home_locator = {
    href = "OEBPS/Text/Section0002.xhtml",
    chapter = "The Lottery",
    text = {
        before = "for a while. Used to be a saying about '",
        after = ".' First thing you know, we'd all be eat",
    },
}
local home_hits = {
    {
        chapter = "The Lottery", text = "Lottery in June, corn be heavy soon",
        before = "for a while. Used to be a saying about \u{2018}",
        after = ".\u{2019} First thing you know,",
        start = "xptr-lottery", finish = "xptr-lottery-end",
    },
    {
        chapter = "The Lottery", text = "Lottery in June, corn be heavy soon",
        before = "a different sentence entirely said",
        after = "and then nothing",
        start = "xptr-lottery-other", finish = "xptr-lottery-other-end",
    },
}
local home_anchor, home_error = Annotations.anchorCandidates(home_hits,
    home_locator, "Lottery in June, corn be heavy soon")
eq(home_error, nil, "hrefless KOReader hit anchors a Home Readium locator")
eq(home_anchor and home_anchor.start, "xptr-lottery",
    "overlapping context selects the matching hit, not the other one")
-- Readium context for a section's first paragraph comes from another spine
-- item (" Unknown "); a single exact in-scope hit still anchors.
local opening, opening_error = Annotations.anchorCandidates({ {
    chapter = "The Lottery", text = "The morning of June 27th was clear and sunny",
    before = "A Short Story by Shirley Jackson",
    after = ", with the fresh warmth",
    start = "xptr-opening", finish = "xptr-opening-end",
} }, {
    href = "OEBPS/Text/Section0002.xhtml", chapter = "The Lottery",
    text = { before = " Unknown ", after = ", with the fresh warmth of a full-summer" },
}, "The morning of June 27th was clear and sunny")
eq(opening_error, nil, "a unique exact hit anchors despite cross-section context")
eq(opening and opening.start, "xptr-opening", "the unique hit is selected")
local _tied, tied_error = Annotations.anchorCandidates({
    home_hits[2],
    { chapter = "The Lottery", text = "Lottery in June, corn be heavy soon",
      before = "yet another place", after = "elsewhere",
      start = "xptr-lottery-third", finish = "xptr-lottery-third-end" },
}, home_locator, "Lottery in June, corn be heavy soon")
eq(tied_error, "ambiguous", "repeated text with no agreeing context is not guessed")
end

group("Annotations.one revisions")
local revisions = {}
local first = Annotations.one(item_a,
    { work_id = "w1", document_hash = "doc", digest = digest, revisions = revisions })
revisions[first.id] = {
    rev = 7,
    signature = Annotations.signature(first, digest),
}
local second = Annotations.one(item_a,
    { work_id = "w1", document_hash = "doc", digest = digest, revisions = revisions })
eq(second.base_rev, 7, "a stored record makes the next push a compare-and-set edit")

local acknowledged_signature = Annotations.signature(first, digest)
local retry, _, already_current =
    Annotations.filterUnchanged({ first }, revisions, digest)
eq(#retry, 0, "an acknowledged payload is not posted a second time")
eq(already_current, 1, "identical annotation is counted as current")

local changed = {}
for key, value in pairs(first) do changed[key] = value end
changed.base_rev = 8
eq(Annotations.signature(changed, digest), acknowledged_signature,
    "compare-and-set revision is excluded from payload identity")
changed.body = "edited note"
local changed_pending, changed_signatures =
    Annotations.filterUnchanged({ changed }, revisions, digest)
eq(#changed_pending, 1, "editing a note schedules a new server update")
ok(changed_signatures[first.id] ~= acknowledged_signature,
    "edited payload gets a distinct acknowledged signature")

local legacy_pending, _, legacy_current =
    Annotations.filterUnchanged({ first }, { [first.id] = 7 }, digest)
eq(#legacy_pending, 1, "legacy revision-only records are sent once")
eq(legacy_current, 0, "legacy records are not assumed acknowledged")

eq(Annotations.signature({
    id = "canonical", locator = { a = 1, b = 2 }, base_rev = 1,
}, digest), Annotations.signature({
    base_rev = 9, locator = { b = 2, a = 1 }, id = "canonical",
}, digest), "nested map order does not change the payload signature")
group("Annotations.batch")
local inputs, skipped = Annotations.batch({
    item_a,
    item_a, -- the same anchor twice
    { datetime = "2026-01-01 10:00:00" }, -- unanchored
    item_b,
}, { work_id = "w1", document_hash = "doc", digest = digest })
eq(#inputs, 2, "duplicates collapse and unanchored entries drop")
eq(skipped["duplicate-anchor"], 1, "duplicate tallied")
eq(skipped["no-anchor"], 1, "unanchored tallied")

group("Annotations.chunk")
local many = {}
for index = 1, 250 do many[index] = { id = index } end
local chunks = Annotations.chunk(many)
eq(#chunks, 3, "250 items become 3 batches")
eq(#chunks[1], 100, "first batch is the server's 100-item maximum")
eq(#chunks[3], 50, "last batch holds the remainder")

group("Annotations server invariants")
-- The pinned contract allows anchored or unanchored notes, and preserves the
-- full palette plus highlight style.
for _, input in ipairs({
    highlight, bookmark, note, paged, no_color, first, second,
}) do
    local locator_present = input.locator ~= nil
    if input.kind == "note" then
        ok((input.body or "") ~= "", "a note requires a body")
    elseif input.kind == "highlight" or input.kind == "bookmark" then
        ok(locator_present, input.kind .. " requires a locator")
    end
    if input.kind == "bookmark" then
        ok(input.body == nil, "a bookmark carries no body")
    end
    if input.color and input.color ~= "" then
        ok(input.kind == "highlight", "colour belongs to a highlight")
        ok(Annotations.color(input.color) ~= nil, "color is a wire palette token")
    end
    if input.drawer and input.drawer ~= "" then
        ok(input.kind == "highlight", "style belongs to a highlight")
        ok(Annotations.drawer(input.drawer) == input.drawer,
            "drawer is a wire style token")
    end
    ok(#input.id <= 64, "id <= 64 bytes")
    ok(#input.work_id <= 128, "work_id <= 128 bytes")
    ok(input.excerpt == nil or #input.excerpt <= 1024, "excerpt <= 1 KiB")
    ok(input.body == nil or #input.body <= 16384, "body <= 16 KiB")
    ok(input.progression == nil
        or (input.progression >= 0 and input.progression <= 1),
        "progression in [0,1]")
    ok(input.client_ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") ~= nil,
        "client_ts is RFC 3339")
    ok(input.base_rev >= 0, "base_rev >= 0")
end

group("AnnotationSync queue and revision conflicts")
local function annotationItem(id, timestamp, body)
    return {
        datetime = timestamp,
        drawer = "invert",
        color = "olive",
        text = "a durable excerpt",
        note = body,
        page = "/body/section/p[1]/text()[1].0",
        pos0 = "/body/section/p[1]/text()[1].0",
        pos1 = "/body/section/p[1]/text()[1].18",
        pageno = 12,
        coppice_id = id,
    }
end

local function wireRecord(input, revision, client_ts)
    local record = Annotations.remoteInput(input)
    record.rev = revision
    record.client_ts = client_ts or input.client_ts
    return record
end

local function annotationServer(seed)
    local server = {
        records = AnnotationSync.copy(seed or {}),
        push_calls = 0,
        delete_calls = 0,
        delete_revisions = {},
        next_seq = 1,
    }
    function server:liseurPushAnnotations(_, batch)
        self.push_calls = self.push_calls + 1
        local results = {}
        for _, input in ipairs(batch) do
            local current = self.records[input.id]
            if current and (current.deleted
                    or tonumber(input.base_rev) ~= tonumber(current.rev)) then
                results[#results + 1] = {
                    id = input.id, status = "conflict",
                    server = AnnotationSync.copy(current),
                }
            else
                local revision = current and tonumber(current.rev) + 1 or 1
                local record = wireRecord(input, revision)
                record.seq = self.next_seq
                self.next_seq = self.next_seq + 1
                self.records[input.id] = record
                results[#results + 1] = {
                    id = input.id, status = "applied", rev = revision,
                }
            end
        end
        return { results = results }
    end
    function server:liseurWorkAnnotations(_, work_id, include_deleted)
        local annotations = {}
        for _, record in pairs(self.records) do
            if record.work_id == work_id
                    and (include_deleted or not record.deleted) then
                annotations[#annotations + 1] =
                    AnnotationSync.copy(record)
            end
        end
        return { annotations = annotations }
    end
    function server:liseurDeleteAnnotation(_, id, revision)
        self.delete_calls = self.delete_calls + 1
        self.delete_revisions[#self.delete_revisions + 1] = revision
        local current = self.records[id]
        if not current then return nil, "not-found", 404 end
        if current.deleted or tonumber(revision) ~= tonumber(current.rev) then
            return nil, "rev conflict", 409, AnnotationSync.copy(current)
        end
        local tombstone = AnnotationSync.copy(current)
        tombstone.rev = tonumber(current.rev) + 1
        tombstone.deleted = true
        tombstone.deleted_at = "2026-01-01T12:00:00Z"
        tombstone.seq = self.next_seq
        self.next_seq = self.next_seq + 1
        self.records[id] = tombstone
        return { rev = tombstone.rev, seq = tombstone.seq }
    end
    return server
end

local sync_options = {
    work_id = "w1",
    document_hash = "doc",
    digest = digest,
    now = 0,
}
local queue_item = annotationItem("queue-id", "2026-01-01T10:00:00Z")
local queue_state = AnnotationSync.newState()
local queued_inputs = AnnotationSync.plan({ queue_item }, queue_state,
    sync_options)
eq(#queued_inputs, 1, "a local annotation becomes one pending upsert")
local queued_id = queued_inputs[1].id
local queued_signature = queue_state.queue[queued_id].signature
eq(queue_state.queue[queued_id].op, "upsert", "offline change is queued")
AnnotationSync.plan({ queue_item }, queue_state, sync_options)
eq(queue_state.queue[queued_id].signature, queued_signature,
    "replanning the same local state is idempotent")
AnnotationSync.accept(queue_state, queued_id, 1, queued_signature,
    queued_inputs[1].client_ts)
AnnotationSync.plan({ queue_item }, queue_state, sync_options)
eq(queue_state.queue[queued_id], nil,
    "an acknowledged unchanged annotation is not requeued")

local edited_item = AnnotationSync.copy(queue_item)
edited_item.note = "edited while offline"
edited_item.datetime_updated = "2026-01-01T11:00:00Z"
local edited_inputs = AnnotationSync.plan({ edited_item }, queue_state,
    sync_options)
eq(#edited_inputs, 1, "editing a synced annotation schedules an update")
eq(edited_inputs[1].base_rev, 1, "edits use the stored compare-and-set revision")
eq(edited_inputs[1].body, "edited while offline", "edit body is queued")
AnnotationSync.plan({}, queue_state, sync_options)
eq(queue_state.queue[queued_id].op, "delete",
    "removing a managed local annotation queues a server delete")
eq(queue_state.queue[queued_id].rev, 1,
    "delete uses the stored server revision")
local delete_client_ts = queue_state.queue[queued_id].client_ts
AnnotationSync.plan({}, queue_state, sync_options)
eq(queue_state.queue[queued_id].client_ts, delete_client_ts,
    "replanning a pending deletion preserves its timestamp")

AnnotationSync.queueSnapshot(queue_state, { queue_item }, "book-1", "doc")
local settings = { data = {} }
function settings:readSetting(key) return self.data[key] end
function settings:saveSetting(key, value) self.data[key] = value end
function settings:flush() self.flushed = true end
AnnotationSync.saveState(settings, queue_state)
local restored = AnnotationSync.loadState(settings)
eq(restored.queue[queued_id].op, "delete",
    "pending action survives persisted per-book state")
eq(restored.snapshot[1].text, "a durable excerpt",
    "offline book snapshot survives persistence")
eq(restored.book_id, "book-1", "queue snapshot is associated with its book")
ok(settings.flushed, "persisting sync state flushes settings")
eq(AnnotationSync.bookKey("book-1", "doc"),
    "book-1" .. string.char(30) .. "doc",
    "different books and documents have distinct queue keys")
local invalid_item = annotationItem("invalid-style-id", "2026-01-01T10:00:00Z")
local invalid_state = AnnotationSync.newState()
AnnotationSync.plan({ invalid_item }, invalid_state, sync_options)
invalid_item.color = "magenta"
local invalid_inputs, invalid_skipped =
    AnnotationSync.plan({ invalid_item }, invalid_state, sync_options)
eq(#invalid_inputs, 0, "unsupported color does not produce a partial payload")
eq(invalid_skipped["unsupported-color"], 1,
    "unsupported color has an explicit skip reason")
eq(invalid_state.queue["invalid-style-id"], nil,
    "a stale valid payload is not sent after its local color becomes invalid")
eq(invalid_item.color, "magenta", "rejected local color remains on the device")
local unsupported_style_item = annotationItem("invalid-drawer-id",
    "2026-01-01T10:00:00Z")
unsupported_style_item.drawer = "mystery"
local unsupported_style_inputs, unsupported_style_skipped =
    AnnotationSync.plan({ unsupported_style_item }, AnnotationSync.newState(),
        sync_options)
eq(#unsupported_style_inputs, 0, "unsupported style does not lose fidelity")
eq(unsupported_style_skipped["unsupported-drawer"], 1,
    "unsupported style is explicitly reported")

local legacy_settings = {
    data = { coppice_annotation_revs = { ["legacy-server-id"] = 7 } },
}
function legacy_settings:readSetting(key) return self.data[key] end
local migrated_state = AnnotationSync.loadState(legacy_settings)
eq(migrated_state.managed["legacy-server-id"], true,
    "legacy acknowledged IDs remain deletion-managed after upgrade")

local conflict_item = annotationItem("conflict-id",
    "2026-01-01T11:00:00Z", "local version")
local conflict_input = Annotations.one(conflict_item, sync_options)
local old_server_input = AnnotationSync.copy(conflict_input)
old_server_input.body = "older server version"
old_server_input.client_ts = "2026-01-01T10:00:00Z"
local conflict_server = annotationServer({
    ["conflict-id"] = wireRecord(old_server_input, 5),
})
local conflict_state = AnnotationSync.newState({
    revisions = { ["conflict-id"] = { rev = 4 } },
})
AnnotationSync.plan({ conflict_item }, conflict_state, sync_options)
local conflict_ok, conflict_result = AnnotationSync.drain(conflict_server,
    "test-secret", conflict_state, sync_options)
ok(conflict_ok, "a newer local edit retries after fetching conflict state")
eq(conflict_server.push_calls, 2, "the conflict is retried with the new revision")
eq(conflict_server.records["conflict-id"].rev, 6,
    "compare-and-set retry advances the server revision")
eq(conflict_server.records["conflict-id"].body, "local version",
    "last-writer-wins keeps the newer local edit")
eq(conflict_state.queue["conflict-id"], nil, "successful retry clears the queue")
eq(conflict_result.conflicts, 1, "conflict is accounted for")

local winner_item = annotationItem("winner-id", "2026-01-01T10:00:00Z",
    "stale local version")
local winner_input = Annotations.one(winner_item, sync_options)
local winner_server_input = AnnotationSync.copy(winner_input)
winner_server_input.body = "server wins"
winner_server_input.client_ts = "2026-01-01T12:00:00Z"
local winner_server_record = wireRecord(winner_server_input, 4)
local winner_server = annotationServer({
    ["winner-id"] = winner_server_record,
})
local winner_state = AnnotationSync.newState({
    revisions = { ["winner-id"] = { rev = 3 } },
})
local winner_sync = AnnotationSync.new({
    api = winner_server, secret = "test-secret", work_id = "w1",
    document_hash = "doc", digest = digest, state = winner_state,
    items = { winner_item },
})
local winner_ok, winner_result = winner_sync:run(false)
ok(winner_ok, "newer server state resolves a revision conflict")
eq(winner_result.conflicts, 1, "server-wins conflict is reported")
eq(winner_server.push_calls, 1, "stale local content is not retried")
eq(winner_sync.items[1].note, "server wins",
    "conflict pull replaces stale local content with server state")
eq(winner_sync.state.queue["winner-id"], nil,
    "server-wins conflict clears the stale local queue action")

local delete_item = annotationItem("delete-conflict-id",
    "2026-01-01T11:00:00Z")
local delete_input = Annotations.one(delete_item, sync_options)
local delete_record_input = AnnotationSync.copy(delete_input)
delete_record_input.client_ts = "2026-01-01T10:00:00Z"
local delete_server = annotationServer({
    ["delete-conflict-id"] = wireRecord(delete_record_input, 5),
})
local delete_state = AnnotationSync.newState({
    revisions = { ["delete-conflict-id"] = { rev = 4 } },
    id_map = { local_delete_id = "delete-conflict-id" },
    managed = { ["delete-conflict-id"] = true },
    queue = {
        ["delete-conflict-id"] = {
            op = "delete", id = "delete-conflict-id", rev = 4,
            client_ts = "2026-01-01T11:00:00Z",
        },
    },
})
local delete_ok = AnnotationSync.drain(delete_server, "test-secret",
    delete_state, sync_options)
ok(delete_ok, "a newer delete retries after a revision conflict")
eq(delete_server.delete_calls, 2, "delete retries once at the current revision")
eq(delete_server.delete_revisions[2], 5,
    "delete retry uses the fetched server revision")
eq(delete_state.revisions["delete-conflict-id"].deleted, true,
    "successful delete stores a tombstone revision")
eq(delete_state.id_map.local_delete_id, nil,
    "successful delete clears the stable local-id mapping")
eq(delete_state.queue["delete-conflict-id"], nil,
    "successful delete clears its queued action")

local tombstone_item = annotationItem("tombstoned-id",
    "2026-01-01T11:00:00Z", "edited after deletion")
local tombstone_input = Annotations.one(tombstone_item, sync_options)
local tombstone_server = annotationServer({
    ["tombstoned-id"] = {
        id = "tombstoned-id", work_id = "w1", rev = 5, deleted = true,
        deleted_at = "2026-01-01T10:00:00Z",
    },
})
local recreated_state = AnnotationSync.newState({
    queue = {
        ["tombstoned-id"] = {
            op = "upsert",
            input = tombstone_input,
            signature = Annotations.signature(tombstone_input, digest),
            client_ts = tombstone_input.client_ts,
        },
    },
})
local recreated_old, recreated_new
local recreated_ok = AnnotationSync.drain(tombstone_server, "test-secret",
    recreated_state, {
        work_id = "w1",
        digest = digest,
        onRecreated = function(old_id, new_id)
            recreated_old, recreated_new = old_id, new_id
            tombstone_item.coppice_id = new_id
        end,
    })
ok(recreated_ok, "newer local edit is recreated instead of reviving a tombstone")
eq(recreated_old, "tombstoned-id", "recreation reports the deleted identity")
ok(recreated_new ~= nil and recreated_new ~= recreated_old,
    "recreation derives a fresh stable identity")
eq(tombstone_server.records["tombstoned-id"].deleted, true,
    "old tombstone is never resurrected")
eq(tombstone_server.records[recreated_new].deleted, nil,
    "new identity receives the post-deletion edit")
eq(recreated_state.queue[recreated_new], nil,
    "successful recreated upsert clears pending work")

group("AnnotationSync pull anchoring and tombstones")
local imported_item = annotationItem("imported-native-id",
    "2026-01-01T10:00:00Z", "remote note")
local imported_input = Annotations.one(imported_item, sync_options)
local imported_record = wireRecord(imported_input, 1)
local imported_state = AnnotationSync.newState()
local imported_items = {}
local reconcile_options = {
    work_id = "w1",
    document_hash = "doc",
    digest = digest,
    items = imported_items,
    default_drawer = "lighten",
}
local import_counts = AnnotationSync.reconcile({ imported_record },
    imported_state, reconcile_options)
eq(import_counts.imported, 1, "first pull imports a native KOReader record")
eq(#imported_items, 1, "one stable native annotation is added")
eq(imported_items[1].coppice_id, "imported-native-id",
    "remote id is mapped onto the local annotation")
local repeat_counts = AnnotationSync.reconcile({ imported_record },
    imported_state, reconcile_options)
eq(repeat_counts.imported, 0, "repeat pull does not duplicate an annotation")
eq(#imported_items, 1, "stable id mapping keeps exactly one local item")
local tombstone_counts = AnnotationSync.reconcile({
    {
        id = "imported-native-id", work_id = "w1", rev = 2,
        deleted = true, deleted_at = "2026-01-01T12:00:00Z",
    },
}, imported_state, reconcile_options)
eq(tombstone_counts.removed, 1, "server tombstone removes imported item")
eq(#imported_items, 0, "deleted remote annotation leaves no native duplicate")

local matched_hit = {
    start = "readium-xptr-start",
    ["end"] = "readium-xptr-end",
    matched_text = "Unique phrase from Readium",
    prev_text = "intro text before",
    next_text = "continuation after text",
}
local readium_document = {}
function readium_document:findAllText()
    return { AnnotationSync.copy(matched_hit) }
end
function readium_document:getPageFromXPointer()
    return 1
end
local toc = { toc = { [1] = { href = "OPS/chapter-one.xhtml" } } }
function toc:getTocTitleByPage() return "Chapter One" end
function toc:getTocIndexByPage() return 1 end
local readium_options = {
    work_id = "w1",
    document_hash = "doc",
    digest = digest,
    items = {},
    document = readium_document,
    ui = { toc = toc },
    default_drawer = "lighten",
}
local readium_record = {
    id = "readium-import-id",
    work_id = "w1",
    kind = "highlight",
    locator = {
        href = "./OPS/chapter-one.xhtml?source=remote",
        chapter = "Chapter One",
        text = { before = "before", after = "continuation" },
    },
    excerpt = "Unique phrase from Readium",
    color = "cyan",
    drawer = "underline",
    client_ts = "2026-01-01T10:00:00Z",
    rev = 1,
}
local readium_counts = AnnotationSync.reconcile({ readium_record },
    AnnotationSync.newState(), readium_options)
eq(readium_counts.imported, 1, "Readium excerpt anchors within its href/chapter")
eq(readium_options.items[1].pos0, "readium-xptr-start",
    "unique Readium text match uses the KOReader search x-pointer")
eq(readium_options.items[1].pos1, "readium-xptr-end",
    "matched excerpt retains both search boundaries")
eq(readium_options.items[1].drawer, "underscore",
    "Readium wire underline restores native style")
eq(readium_options.items[1].color, "cyan",
    "Readium color is preserved on import")
local unanchored_record = AnnotationSync.copy(readium_record)
unanchored_record.id = "readium-unanchored-id"
unanchored_record.locator.href = "OPS/not-this-chapter.xhtml"
local unanchored_state = AnnotationSync.newState()
local unanchored_options = AnnotationSync.copy(readium_options)
unanchored_options.items = {}
local unanchored_counts = AnnotationSync.reconcile({ unanchored_record },
    unanchored_state, unanchored_options)
eq(unanchored_counts.remote, 1, "out-of-scope Readium excerpt is not guessed")
eq(unanchored_state.remote_notes["readium-unanchored-id"].reason, "not-found",
    "unanchorable annotation is available to the remote-notes view")
eq(#unanchored_options.items, 0,
    "unanchorable server record is not inserted into KOReader annotations")
local saturated_options = AnnotationSync.copy(readium_options)
saturated_options.items = {}
function saturated_options.document:findAllText()
    local hits = {}
    for index = 1, 2048 do hits[index] = AnnotationSync.copy(matched_hit) end
    return hits
end
local saturated_record = AnnotationSync.copy(readium_record)
saturated_record.id = "readium-saturated-id"
local saturated_state = AnnotationSync.newState()
local saturated_counts = AnnotationSync.reconcile({ saturated_record },
    saturated_state, saturated_options)
eq(saturated_counts.remote, 1, "search result cap never becomes a guessed anchor")
eq(saturated_state.remote_notes["readium-saturated-id"].reason,
    "too-many-matches", "saturated search remains in Remote notes")
eq(#saturated_options.items, 0, "saturated search does not import an item")


-- --------------------------------------------------------------- kosync

group("KoSync.settingsPatch")
local patch = KoSync.settingsPatch("http://host:10801", "coppice_KEY", "alice")
eq(patch.custom_server, "http://host:10801/koreader/coppice_KEY",
    "the built-in client is pointed at the key-in-path endpoint")
eq(patch.checksum_method, 0,
    "BINARY: Coppice only matches the partial MD5, so FILENAME would 404 every push")
eq(patch.username, "alice", "username is filled in (the client refuses to sync without one)")
ok((patch.userkey or "") ~= "", "userkey is non-empty (Coppice ignores its value)")
local anon = KoSync.settingsPatch("http://host", "coppice_KEY", nil)
eq(anon.username, "coppice", "a missing username still yields a usable value")
local none, err = KoSync.settingsPatch("http://host", nil, "alice")
eq(none, nil, "no API key, no patch")
eq(err, "no_api_key", "and the reason says why")
local previous_kosync = {
    custom_server = "https://sync.example",
    username = "reader",
    userkey = "prior-digest",
    checksum_method = 1,
    auto_sync = true,
}
local backup = KoSync.capturePreviousSettings(previous_kosync,
    patch.custom_server, nil)
local managed_kosync = {}
for key, value in pairs(previous_kosync) do managed_kosync[key] = value end
for key, value in pairs(patch) do managed_kosync[key] = value end
local rotated_server = "http://host:10801/koreader/new-key"
local rotated_backup = KoSync.capturePreviousSettings(managed_kosync,
    rotated_server, backup)
local rotated_kosync = {}
for key, value in pairs(managed_kosync) do rotated_kosync[key] = value end
rotated_kosync.custom_server = rotated_server
rotated_kosync.userkey = "new-digest"
local restored_kosync, restored_owned = KoSync.restoreSettings(
    rotated_kosync, rotated_server, rotated_backup)
eq(restored_owned, true, "restore applies only to the active Coppice KOSync target")
eq(restored_kosync.custom_server, "https://sync.example",
    "prior custom server is restored after forgetting Coppice")
eq(restored_kosync.userkey, "prior-digest", "prior KOSync auth is restored")
eq(restored_kosync.auto_sync, true, "unrelated KOSync preferences survive")

local legacy_restored, legacy_owned = KoSync.restoreSettings(managed_kosync,
    patch.custom_server, nil)
eq(legacy_owned, true, "legacy Coppice KOSync settings can be forgotten")
eq(legacy_restored.custom_server, nil, "legacy target is removed without a backup")
eq(legacy_restored.userkey, nil, "legacy secret digest is removed")
eq(legacy_restored.auto_sync, true, "legacy cleanup preserves unrelated preferences")
local untouched, still_owned =
    KoSync.restoreSettings({ custom_server = "https://other" },
        patch.custom_server, backup)
eq(untouched, nil, "a user-changed KOSync target is not overwritten")
eq(still_owned, false, "ownership check reports the changed target")

-- --------------------------------------------------------------- pairing

local Pairing = require("coppice_pairing")
local Migration = require("coppice_migration")

group("Pairing.credentials")

local Fixtures = require("pairing")
local approved = Fixtures.approved
local lanes = Pairing.credentials(approved)
eq(lanes.api_key, "fixture-api", "API lane uses kind and protocol")
eq(lanes.liseur_secret, "fixture-liseur", "liseur lane uses kind and protocol")
eq(lanes.username, "fixture-user", "approved username is retained")
eq(lanes.device_id, "fixture-device", "device metadata is retained")
local endpoint_order = {
    status = "approved",
    credentials = approved.credentials,
    endpoints = {
        { protocol = "api", username = "zeta" },
        { protocol = "api", username = "alpha" },
    },
}
local endpoint_lanes = Pairing.credentials(endpoint_order)
eq(endpoint_lanes.username, "alpha",
    "endpoint metadata fallback is deterministic, not list-order based")

local singular = {
    status = "approved",
    username = "alice",
    credential = { kind = "api_key", protocol = "koreader", secret = "key" },
}
local missing, missing_err = Pairing.credentials(singular)
eq(missing, nil, "singular API-only response is rejected")
eq(missing_err, "missing_liseur_token", "partial credential response is explicit")
eq(Pairing.statusMessage("denied"), "Pairing was denied. Start a new pairing to try again.",
    "denial has a restart instruction")
eq(Pairing.statusMessage("expired"), "Pairing expired. Start a new pairing to try again.",
    "expiry has a restart instruction")
eq(Pairing.pollInterval({ poll_interval_secs = 120 }, 2), 30,
    "poll interval is bounded")
eq(Pairing.formatCode("959477"), "959 477", "six-digit code is grouped")
eq(Pairing.formatCode(959477), "959 477", "numeric code is grouped")
eq(Pairing.formatCode("12ab"), "12ab", "malformed code is shown unchanged")
eq(Pairing.parseUtc("2026-09-24T05:58:54Z"), 1790229534, "RFC 3339 UTC parses to epoch")
eq(Pairing.parseUtc("2026-09-24T05:58:54.123Z"), 1790229534, "fractional seconds are accepted")
eq(Pairing.parseUtc("2026-09-24T05:58:54+02:00"), nil, "non-UTC offsets are rejected")
eq(Pairing.parseUtc("2000-03-01T00:00:00Z"), 951868800, "leap-year boundary is correct")
eq(Pairing.expiresIn("2026-09-24T05:58:54Z", 1790229534 - 541), "expires in 10 min",
    "minutes round up")
eq(Pairing.expiresIn("2026-09-24T05:58:54Z", 1790229534 - 40), "expires in 40 s",
    "final minute shows seconds")
eq(Pairing.expiresIn("2026-09-24T05:58:54Z", 1790229534), "expired", "at expiry is expired")
eq(Pairing.expiresIn("garbage", 1), nil, "unparseable expiry is omitted")

group("Migration.removalPlan")
local plan = Migration.removalPlan("/plugins", "/settings")
eq(plan[1], "/settings/stump.lua", "legacy settings are explicitly retired")
ok(#plan >= 10, "all known legacy plugin files are covered")
local removed, removed_dir = {}, nil
Migration.run("/plugins", "/settings",
    function(path) removed[#removed + 1] = path end,
    function(path) removed_dir = path end)
eq(removed_dir, "/plugins/stump.koplugin", "old directory is removed only after files")
ok(#removed == #plan, "migration removes only its explicit plan")

-- -------------------------------------------------------------- catalog UI

group("Catalog.layout and paging")
local function fits(l, width)
    return l.tile_width * l.columns + l.gap * (l.columns - 1) + 2 * l.margin <= width
end
-- The user's phone: 1096x2560 px at ~2.75x density.
local phone = Catalog.layout(1096, 2560, 2.75)
eq(phone.columns, 3, "a phone gets three covers across, not four tiny ones")
ok(phone.rows >= 4, "a tall phone fills its height with more rows")
eq(phone.page_size, phone.columns * phone.rows, "page size is columns x rows")
ok(fits(phone, 1096), "phone tiles and gaps fit the width")
-- Kobo Clara-class 1072x1448 at 300 dpi (1.875x).
local kobo = Catalog.layout(1072, 1448, 1.875)
eq(kobo.columns, 4, "a Kobo gets four covers across")
eq(kobo.rows, 3, "a Kobo gets three rows")
ok(fits(kobo, 1072), "Kobo tiles and gaps fit the width")
-- Narrow screen never drops below two columns.
eq(Catalog.layout(320, 800, 2).columns, 2, "narrow screens keep two columns")
ok(kobo.tile_width >= 48 and kobo.cover_height >= 48, "tiles exceed the minimum touch target")
local page_items, page, page_count = Catalog.page({ "a", "b", "c", "d", "e" }, 2, 2)
eq(table.concat(page_items, ","), "c,d", "page selects the correct slice")
eq(page, 2, "page is retained when in range")
eq(page_count, 3, "last partial page counts")
local last_items, last_page, last_count = Catalog.page({ "a", "b", "c" }, 99, 2)
eq(table.concat(last_items, ","), "c", "page selects only its visible page")
eq(last_page, 2, "page clamp is reported")
eq(last_count, 2, "page count is rounded up")
eq(Catalog.visiblePage({ "a", "b", "c", "d", "e" }, 2, 2)[1], "c",
    "oversized response is sliced before widgets are created")
eq(Catalog.pageLabel(305, "books", "Title (A–Z)"),
    "305 books · Sort: Title (A–Z)", "subtitle separates sort from footer pagination")

group("Catalog search and local stats")
local search_query, search_variables = Catalog.searchRequest("earthsea", 50)
ok(search_query:find("searchBooks(query: $query, limit: $limit)", 1, true) ~= nil,
    "search uses the server searchBooks query")
eq(search_variables.query, "earthsea", "search query is passed unchanged")
eq(search_variables.limit, 50, "search result limit is bounded")
local _, minimum_search_variables = Catalog.searchRequest("x", 0)
eq(minimum_search_variables.limit, 1, "search limit cannot be zero")
local stats_query = Catalog.statisticsQuery()
ok(stats_query:find("FROM page_stat", 1, true) ~= nil
        and stats_query:find("date(start_time, 'unixepoch', 'localtime')", 1, true) ~= nil,
    "reading stats aggregate the local page_stat view by local day")
local local_stats = Catalog.readingStats({
    { days_ago = 0, pages = 8, seconds = 601 },
    { days_ago = 1, pages = 12, seconds = 900 },
    { days_ago = 2, pages = 7, seconds = 120 },
    { days_ago = 8, pages = 30, seconds = 60 },
})
eq(local_stats.today_pages, 8, "today page count is isolated")
eq(local_stats.today_minutes, 10, "today duration is rounded to minutes")
eq(local_stats.week_pages, 27, "seven-day page totals exclude older days")
eq(local_stats.week_minutes, 27, "seven-day duration totals exclude older days")
eq(local_stats.streak_days, 3, "streak counts consecutive reading days")
local no_today = Catalog.readingStats({
    { days_ago = 1, pages = 2, seconds = 61 },
    { days_ago = 2, pages = 3, seconds = 60 },
    { days_ago = 4, pages = 99, seconds = 60 },
})
eq(no_today.streak_days, 2, "streak starts yesterday if today has no activity")

group("Catalog home actions and recent annotations")
eq(Catalog.continueTapAction({ local_path = "/books/a.epub" }, true), "open",
    "downloaded continue card opens directly")
eq(Catalog.continueTapAction({ local_path = "/books/a.epub" }, false), "detail",
    "missing continue file opens book details")
eq(Catalog.continueTapAction({}, true), "detail", "continue card without path opens details")
local annotations = Catalog.recentAnnotations({
    { id = "old", kind = "highlight", updated_at = "2026-09-20T00:00:00Z",
        excerpt = string.rep("e", 400), body = string.rep("n", 200) },
    { id = "new", kind = "note", updated_at = "2026-09-24T00:00:00Z",
        excerpt = "recent", body = "note" },
    { id = "bookmark", kind = "bookmark", updated_at = "2026-09-25T00:00:00Z" },
    { id = "middle", drawer = "blue", updated_at = "2026-09-22T00:00:00Z",
        excerpt = "middle" },
}, 2)
eq(#annotations, 2, "recent annotation cards are capped")
eq(annotations[1].id, "new", "recent annotations are sorted newest first")
eq(annotations[2].id, "middle", "highlights are included but bookmarks are omitted")
eq(annotations[2].excerpt, "middle", "highlight excerpt stays with its newest row")
eq(#annotations[2].body, 0, "empty highlight note stays empty")
local old_highlight = Catalog.recentAnnotations({
    { id = "old", kind = "highlight", updated_at = "2026-09-20T00:00:00Z",
        excerpt = string.rep("e", 400), body = string.rep("n", 200) },
}, 1)[1]
eq(#old_highlight.excerpt, 360, "highlight excerpts are bounded")
eq(#old_highlight.body, 180, "highlight note previews are bounded")
local long_note = Catalog.recentAnnotations({
    { id = "long", kind = "note", updated_at = "2026-09-24T00:00:00Z",
        body = string.rep("n", 240) },
}, 1)[1]
eq(#long_note.body, 180, "note previews are bounded")
local cross_source = Catalog.recentAnnotations({
    { id = "koreader", kind = "highlight", updated_at = "2026-09-25T00:00:00Z",
        device_id = "KOReader Android", excerpt = "local highlight" },
    { id = "readium", kind = "note", updated_at = "2026-09-24T00:00:00Z",
        device_id = "Readium reader", body = "Readium note" },
    { id = "liseur", kind = "note", updated_at = "2026-09-23T00:00:00Z",
        device_id = "Liseur desktop", body = "Remote note" },
    { id = "older", kind = "highlight", updated_at = "2026-09-22T00:00:00Z",
        excerpt = "Older highlight" },
    { id = "outside", kind = "highlight", updated_at = "2026-09-21T00:00:00Z",
        excerpt = "Outside latest four" },
    { id = "bookmark", kind = "bookmark", updated_at = "2026-09-26T00:00:00Z" },
}, 4)
eq(#cross_source, 4, "Home selects four recent annotations across sources")
eq(cross_source[1].id, "koreader", "cross-source entries stay newest-first")
eq(cross_source[4].id, "older", "oldest eligible annotation falls off after four")
eq(Catalog.annotationSource(cross_source[1]), "KOReader", "KOReader annotation source is labelled")
eq(Catalog.annotationSource(cross_source[2]), "Home/Readium",
    "Readium annotation source is labelled")
eq(Catalog.annotationSource(cross_source[3]), "Liseur",
    "liseur annotation source is labelled")
ok(Catalog.isPositionedAnnotation({ locator = { page = 3 } }),
    "nested remote page positions are recognized")
ok(not Catalog.isPositionedAnnotation({ locator = { href = "/chapter.xhtml" } }),
    "unplaceable annotation locator is not treated as positioned")

group("Catalog.media mapping")
local mapped = Catalog.media({
    id = "media-1",
    name = "filename",
    extension = "epub",
    pages = 200,
    metadata = {
        title = "Mapped title",
        writers = { "A. Author", "B. Author" },
        year = 2024,
        publisher = "Press",
        pageCount = 198,
        summary = "A summary",
    },
    tags = { { name = "Fantasy" }, { name = "Adventure" } },
    series = { id = "series-1", name = "Saga" },
    readProgress = { percentageCompleted = 0.425, page = 85 },
})
eq(mapped.title, "Mapped title", "metadata title takes precedence")
eq(mapped.authors, "A. Author, B. Author", "writer list is displayed")
eq(mapped.pages, 198, "metadata page count takes precedence")
eq(mapped.tags[2], "Adventure", "tag names are extracted")
eq(mapped.series_id, "series-1", "series identity is retained")
eq(mapped.progression, 43, "fractional progress rounds to a percent")
eq(mapped.page, 85, "page-addressed position is retained")
local continue_item = Catalog.continueItem({
    mediaId = "media-2", name = "Continue", progression = 0.36,
    page = 42, pages = 117, extension = "pdf",
})
eq(continue_item.id, "media-2", "continue response maps media id")
eq(continue_item.progression, 36, "continue response maps progress")
eq(continue_item.page, 42, "continue response maps page")

group("Catalog audiobooks")
ok(Catalog.isAudiobook({ extension = "m4b" }), "m4b is an audiobook")
ok(Catalog.isAudiobook({ extension = ".MP3" }), "extension check is case and dot insensitive")
ok(Catalog.isAudiobook({ extension = "epub", audio = { durationMs = 1 } }), "server audio block marks an audiobook")
ok(not Catalog.isAudiobook({ extension = "epub" }), "an EPUB is not an audiobook")
eq(Catalog.media({ id = "a", extension = "mp3" }).is_audiobook, true, "mapped media carries the audiobook flag")
eq(Catalog.media({ id = "a", extension = "mp3" }).extension, nil, "audio is never offered as a download")
local edition = Catalog.readableEdition({
    { id = "x", extension = "m4b" },
    { id = "e", resolvedName = "Ender's Game", extension = "epub" },
})
eq(edition and edition.id, "e", "the first readable edition is chosen")
eq(edition and edition.extension, "epub", "readable edition keeps its format")
eq(Catalog.readableEdition({ { id = "x", extension = "m4b" } }), nil, "no readable edition means none")
eq(Catalog.readableEdition(nil), nil, "missing editions are tolerated")

group("Catalog reading time")
eq(Catalog.durationLabel(0), "0m", "no reading is 0m")
eq(Catalog.durationLabel(45), "45m", "under an hour is minutes")
eq(Catalog.durationLabel(180), "3h", "whole hours drop minutes")
eq(Catalog.durationLabel(190), "3h 10m", "hours and minutes")
eq(Catalog.readingStats({}).has_data, false, "no statistics rows means no reading stats")

group("Catalog server annotations")
local recent_query, recent_vars = Catalog.recentAnnotationsRequest(4)
ok(recent_query:find("order: RECENT", 1, true) ~= nil, "recent feed asks the server for newest first")
ok(recent_query:find("kind: [HIGHLIGHT, NOTE]", 1, true) ~= nil, "bookmarks are left out")
eq(recent_vars.pagination.pageSize, 4, "four items are requested")
eq(select(2, Catalog.recentAnnotationsRequest(500)).pagination.pageSize, 20, "request size is bounded")
local mapped_note = Catalog.serverAnnotation({
    id = 7, kind = "NOTE", source = "LISEUR", sourceDeviceName = "Pixel",
    color = "green", excerpt = "the passage", note = "my note",
    updatedAt = "2026-09-24T05:23:15.4917+00:00", book = { mediaId = "m1", title = "Ender's Game" },
})
eq(mapped_note.id, "7", "ids are strings")
eq(mapped_note.kind, "note", "kind is lowercased for the card")
eq(mapped_note.source, "Liseur · Pixel", "source label names the device")
eq(mapped_note.book_id, "m1", "book link is kept for open/jump")
eq(mapped_note.body, "my note", "note text becomes the card body")
eq(mapped_note.excerpt, "the passage", "passage is kept")
eq(Catalog.serverAnnotation({ id = 1, source = "WEB", book = {} }).source, "Home", "web source reads as Home")
eq(Catalog.serverAnnotation({ kind = "NOTE" }), nil, "entries without an id are dropped")
eq(Catalog.serverAnnotation({ id = 2, source = "COPPICE", sourceDeviceName = "KOReader test", book = {} }).source,
    "KOReader test", "Coppice reader clients are labelled by their device name")
eq(select(2, Catalog.recentAnnotationsRequest(6, 3)).pagination.page, 3, "all-notes screen requests the chosen page")
ok(Catalog.recentAnnotationsRequest(6, 1):find("total", 1, true) ~= nil, "all-notes screen gets the total for paging")
local utc_base = Catalog.utcEpoch(2026, 9, 24, 12, 0, 0)
eq(Catalog.utcEpoch(1970, 1, 1, 0, 0, 0), 0, "UTC epoch starts at 1970")
for _unused, instant in ipairs({ 1768478400, 1784116800, os.time() }) do
    local u = os.date("!*t", instant)
    eq(Catalog.utcEpoch(u.year, u.month, u.day, u.hour, u.min, u.sec), instant,
        "UTC calendar time round-trips to the same instant")
end
eq(Catalog.relativeTime("2026-09-24T11:47:00.820164765Z", utc_base), "13m ago",
    "a summer UTC stamp is not shifted by daylight saving")
eq(Catalog.relativeTime("2026-09-24T10:00:00+00:00", utc_base), "2h ago", "+00:00 is read as UTC")
eq(Catalog.relativeTime("2026-09-24T10:00:00.123456789Z", utc_base), "2h ago", "fractional Z stamps parse")
eq(Catalog.relativeTime("2026-09-24T11:00:00+01:00", utc_base), "2h ago", "positive offsets are subtracted")
eq(Catalog.relativeTime("2026-09-24T09:00:00-01:00", utc_base), "2h ago", "negative offsets are added")

group("Catalog URLs and bounded cache")
eq(Catalog.coverUrl("http://books.test", { id = "m/1", cover_kind = "media" }),
    "http://books.test/api/v2/media/m%2F1/thumbnail", "media cover route escapes ids")
eq(Catalog.coverUrl("http://books.test", { id = "s-1", cover_kind = "series" }),
    "http://books.test/api/v2/series/s-1/thumbnail", "series cover route is authenticated API")
eq(Catalog.coverUrl("http://books.test", { id = "author", cover_kind = "placeholder" }),
    nil, "placeholder cards never request a media or series thumbnail")
eq(Catalog.cacheFileName("placeholder", "author"), nil,
    "placeholder cards do not occupy image cache entries")
eq(Catalog.cacheFileName("media", "abc-123"), "media-abc-123.jpg",
    "cache names do not include raw URLs")
local evicted, remaining = Catalog.cacheEvictions({
    { name = "old", path = "/cache/old", size = 8, modified = 1 },
    { name = "new", path = "/cache/new", size = 7, modified = 2 },
    { name = "newest", path = "/cache/newest", size = 6, modified = 3 },
}, 12)
eq(table.concat(evicted, ","), "/cache/old,/cache/new",
    "least recently used covers are evicted first")
eq(remaining, 6, "cache remains within its byte budget")

group("Catalog.reader formats")
eq(Catalog.readerExtension("EPUB"), "epub", "reader format matching is case-insensitive")
eq(Catalog.readerExtension("../m4b"), nil, "unsafe and non-reader formats are rejected")
eq(Catalog.readerExtension("fb2.zip"), "fb2.zip", "compound supported format is retained")
eq(Catalog.cacheFileName("media", "abc-123"), "media-abc-123.jpg",
    "cache extension is recognized by KOReader's image registry")
-- ----------------------------------------------------------------- report

io.write(string.format("\n%d passed, %d failed (%s)\n", passed, failed, _VERSION))
os.exit(failed == 0 and 0 or 1)
