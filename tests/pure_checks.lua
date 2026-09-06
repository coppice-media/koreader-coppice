--[[--
Checks for the plugin's pure functions: URL building, OPDS 2.0 mapping,
annotation mapping, and the kosync settings patch.

Runs under plain `lua` or `luajit` — no KOReader, no network. The few
KOReader modules `stump_kosync` pulls in are stubbed below; the three genuinely
pure modules (`stump_url`, `stump_opds`, `stump_annotations`) need no stubs at
all, which is why they are shaped that way.

    lua tests/pure_checks.lua
    luajit tests/pure_checks.lua

A real device run is a different thing and this does not substitute for it:
every rule asserted here about the *server* is the server's rule, taken from
Stump's own source, and is verified separately with curl against a live Stump.
]]

local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../stump.koplugin/?.lua;" .. package.path

-- ------------------------------------------------------------------ stubs

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp/stump-test-settings" end }
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

local Url = require("stump_url")
local Opds = require("stump_opds")
local Annotations = require("stump_annotations")
local KoSync = require("stump_kosync")

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
eq(Url.normalizeBase("http://host/koreader/stump_abc123"), "http://host",
    "pasted kosync endpoint")
eq(Url.normalizeBase("http://host/api/v2/health"), "http://host", "pasted API path")
eq(Url.normalizeBase("host:10801"), nil, "a bare host is not guessed")
eq(Url.normalizeBase("ftp://host"), nil, "non-http scheme rejected")
eq(Url.normalizeBase("http://"), nil, "scheme with no host rejected")
eq(Url.normalizeBase(""), nil, "empty rejected")
eq(Url.normalizeBase(nil), nil, "nil rejected")

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
eq(Url.kosync("http://h", "stump_K"), "http://h/koreader/stump_K",
    "kosync base is what the built-in client wants")
eq(Url.kosyncAuth("http://h", "stump_K"), "http://h/koreader/stump_K/users/auth",
    "kosync auth route")
eq(Url.kosyncPutProgress("http://h", "stump_K"),
    "http://h/koreader/stump_K/syncs/progress", "kosync push route")
eq(Url.kosyncGetProgress("http://h", "stump_K", "deadbeef"),
    "http://h/koreader/stump_K/syncs/progress/deadbeef", "kosync pull route")
eq(Url.kosync("http://h", nil), nil, "no key, no kosync URL")
eq(Url.kosyncGetProgress("http://h", "stump_K", ""), nil, "no document, no pull URL")

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
    metadata = { title = "Stump OPDS V2 Catalog" },
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
eq(view.title, "Stump OPDS V2 Catalog", "feed title")
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
eq(Annotations.color("yellow"), "yellow", "palette token passes")
eq(Annotations.color("Purple"), "purple", "case-insensitive")
eq(Annotations.color("magenta"), "pink", "aliased onto a palette token")
eq(Annotations.color("red"), nil, "a colour outside the palette is dropped, not guessed")
eq(Annotations.color("olive"), nil, "another KOReader-only colour dropped")

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
do
    -- The conversion must be local -> UTC, so formatting the parsed instant
    -- back in local time must return the original string.
    local original = "2026-03-04 05:06:07"
    local iso = Annotations.clientTs(original)
    local y, mo, d, h, mi, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z")
    -- Re-derive the epoch the function used and re-format it locally.
    local epoch = os.time({ year = tonumber(y), month = tonumber(mo),
        day = tonumber(d), hour = tonumber(h), min = tonumber(mi),
        sec = tonumber(s), isdst = false })
    local offset = os.difftime(epoch, os.time(os.date("!*t", epoch)))
    eq(os.date("%Y-%m-%d %H:%M:%S", epoch + offset), original,
        "local wall-clock time round-trips through UTC")
end

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
    note = "a note the server will not accept here",
    color = "yellow",
}, { work_id = "w1", document_hash = "d1", page_count = 100, digest = digest })
eq(bookmark.kind, "bookmark", "no drawer means bookmark")
eq(bookmark.body, nil, "the server rejects a body on a bookmark, so none is sent")
eq(bookmark.color, nil, "the server rejects a colour outside a highlight")
ok(bookmark.locator ~= nil, "a bookmark still needs its locator")

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

local no_color = Annotations.one({
    datetime = "2026-01-01 13:00:00", drawer = "lighten", color = "red",
    page = "/body/p[1]", pos0 = "/body/p[1].0",
}, { work_id = "w1", digest = digest })
eq(no_color.color, nil, "an unmapped colour is omitted rather than rejected by the server")

eq(Annotations.one({ datetime = "2026-01-01 10:00:00" },
    { work_id = "w1", digest = digest }), nil, "no anchor, no annotation")
local _unused, reason = Annotations.one({ datetime = "x" },
    { work_id = "w1", digest = digest })
eq(reason, "no-anchor", "and the reason is reported")
eq(Annotations.one({ page = "/body/p" }, { digest = digest }), nil,
    "no work id, no annotation")

group("Annotations.one revisions")
local revisions = {}
local first = Annotations.one(item_a,
    { work_id = "w1", document_hash = "doc", digest = digest, revisions = revisions })
revisions[first.id] = 7
local second = Annotations.one(item_a,
    { work_id = "w1", document_hash = "doc", digest = digest, revisions = revisions })
eq(second.base_rev, 7, "a known revision makes the next push a compare-and-set edit")

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
-- The rules validate_annotation() enforces, asserted over everything above.
for _, input in ipairs({ highlight, bookmark, paged, no_color, first, second }) do
    local locator_present = input.locator ~= nil
    if input.kind == "note" then
        ok(not locator_present, "a note carries no locator")
        ok((input.body or "") ~= "", "a note requires a body")
    else
        ok(locator_present, input.kind .. " requires a locator")
    end
    if input.kind == "bookmark" then
        ok(input.body == nil, "a bookmark carries no body")
    end
    if input.color then
        ok(input.kind == "highlight", "colour belongs to a highlight")
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

-- --------------------------------------------------------------- kosync

group("KoSync.settingsPatch")
local patch = KoSync.settingsPatch("http://host:10801", "stump_KEY", "alice")
eq(patch.custom_server, "http://host:10801/koreader/stump_KEY",
    "the built-in client is pointed at the key-in-path endpoint")
eq(patch.checksum_method, 0,
    "BINARY: Stump only matches the partial MD5, so FILENAME would 404 every push")
eq(patch.username, "alice", "username is filled in (the client refuses to sync without one)")
ok((patch.userkey or "") ~= "", "userkey is non-empty (Stump ignores its value)")
local anon = KoSync.settingsPatch("http://host", "stump_KEY", nil)
eq(anon.username, "stump", "a missing username still yields a usable value")
local none, err = KoSync.settingsPatch("http://host", nil, "alice")
eq(none, nil, "no API key, no patch")
eq(err, "no_api_key", "and the reason says why")

-- ----------------------------------------------------------------- report

io.write(string.format("\n%d passed, %d failed (%s)\n", passed, failed, _VERSION))
os.exit(failed == 0 and 0 or 1)
