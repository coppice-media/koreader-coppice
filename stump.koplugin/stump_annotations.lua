--[[--
KOReader `doc_settings.annotations` -> Stump liseur-sync `AnnotationInput`.

Pure mapping, no I/O. Every rule below is the *server's* rule, taken from
`crates/liseur-sync/src/lib.rs::validate_annotation`:

* `kind` is exactly one of `highlight`, `note`, `bookmark`.
* `highlight` and `bookmark` require a locator; `note` forbids one and
  requires a body.
* a `bookmark` carries no body.
* `color` only on a `highlight`, and only the six palette tokens
  `yellow green blue pink purple orange`.
* `progression` in `[0,1]`; `client_ts` RFC 3339 and at most 24 h ahead.
* `id` <= 64 bytes, `work_id` <= 128, `excerpt` <= 1 KiB, `body`/`locator`
  <= 16 KiB.

The KOReader side is `ReaderAnnotation:buildAnnotation`: one flat table per
annotation with `datetime`, `drawer`, `color`, `text` (the highlighted
passage), `note` (the user's own note), `chapter`, `pageno`, `pageref`,
`page`, `pos0`, `pos1`, `pboxes`, `ext`. `page`/`pos0`/`pos1` are crengine DOM
x-pointer *strings* for a reflowable book and `{x,y,page}` *tables* for a
paged one; the two formats are not interchangeable, so both travel verbatim
inside the opaque locator and neither is converted into the other.

Two mappings are deliberately absent:

* `note` is never produced. Every KOReader annotation is anchored, and the
  liseur `note` kind is defined as the *unanchored* one. A highlight that has
  a user note becomes a `highlight` whose `body` is that note — the same
  choice Stump documents for its own `media_annotations` projection.
* the x-pointer is never turned into a Readium locator or a CFI. It is a
  crengine DOM pointer; converting it would fabricate an anchor.
]]

local Annotations = {}

Annotations.MAX_ID_BYTES = 64
Annotations.MAX_EXCERPT_BYTES = 1024
Annotations.MAX_BODY_BYTES = 16 * 1024
Annotations.MAX_LOCATOR_BYTES = 16 * 1024
Annotations.LOCATOR_FORMAT = "koreader-annotation"
Annotations.LOCATOR_VERSION = 1

-- The liseur palette. KOReader offers more colours than this (`red`, `olive`,
-- `cyan`, `gray`); an unmapped colour is dropped rather than mapped onto a
-- neighbour, because a wrong colour is worse than no colour and the server
-- rejects anything outside the six tokens.
local COLOR_MAP = {
    yellow = "yellow",
    green = "green",
    blue = "blue",
    pink = "pink",
    purple = "purple",
    orange = "orange",
    magenta = "pink",
    violet = "purple",
}

function Annotations.color(value)
    if type(value) ~= "string" then return nil end
    return COLOR_MAP[value:lower()]
end

--- Truncates to a byte budget without splitting a UTF-8 sequence.
---
--- The server counts bytes; Lua's `#` counts bytes; a naive `sub` can leave a
--- half sequence that makes the whole batch invalid JSON on some decoders.
function Annotations.clip(value, max_bytes)
    if type(value) ~= "string" then return nil end
    if value == "" then return nil end
    if #value <= max_bytes then return value end
    local cut = max_bytes
    -- Walk back off continuation bytes (0b10xxxxxx).
    while cut > 0 do
        local byte = value:byte(cut + 1)
        if byte == nil or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    if cut <= 0 then return nil end
    return value:sub(1, cut)
end

--- KOReader `datetime` ("%Y-%m-%d %H:%M:%S", device local time) -> RFC 3339 UTC.
---
--- `os.time` interprets a table as local time and `os.date("!...")` formats as
--- UTC, so the pair converts without needing to know the offset. A missing or
--- unparseable datetime falls back to `now`, because `client_ts` is required
--- and an annotation with no timestamp is still a real annotation.
function Annotations.clientTs(datetime, now)
    now = now or os.time()
    if type(datetime) == "string" then
        local year, month, day, hour, minute, second =
            datetime:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)")
        if year then
            local epoch = os.time({
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(minute),
                sec = tonumber(second),
                isdst = false,
            })
            if epoch then
                return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
            end
        end
    end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", now)
end

--- Is this annotation a highlight (KOReader draws it) or a page bookmark?
---
--- `drawer` is the highlight style and is `nil` exactly for a page bookmark
--- (`ReaderAnnotation:updateItemByXPointer` uses the same test).
function Annotations.kind(item)
    if type(item) ~= "table" then return nil end
    if item.drawer then return "highlight" end
    return "bookmark"
end

--- The opaque reader-native anchor.
---
--- liseur-sync replays the locator verbatim and never parses it, so this keeps
--- every KOReader field that identifies the anchor and nothing that does not:
--- no `pboxes` (mupdf render boxes, rewritten by KOReader itself), no
--- `pageref` (a display string), no `text`/`note` (they are `excerpt`/`body`).
function Annotations.locator(item, document_hash)
    if type(item) ~= "table" then return nil end
    if item.page == nil and item.pos0 == nil then return nil end
    return {
        format = Annotations.LOCATOR_FORMAT,
        version = Annotations.LOCATOR_VERSION,
        document = document_hash,
        page = item.page,
        pos0 = item.pos0,
        pos1 = item.pos1,
        pageno = item.pageno,
        chapter = item.chapter,
        drawer = item.drawer,
        ext = item.ext,
    }
end

--- Whole-publication progression, or nil.
---
--- `pageno` is KOReader's continuous page number; dividing by the page count
--- is the only progression available without asking the document engine, and
--- it is the same quantity Stump's `reading_heads.progression` holds.
function Annotations.progression(item, page_count)
    local page = tonumber(item and item.pageno)
    local total = tonumber(page_count)
    if not page or not total or total <= 0 then return nil end
    local value = page / total
    if value ~= value then return nil end
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

--- A stable per-annotation id.
---
--- The id is the compare-and-set key: the same annotation pushed twice must
--- produce the same id or the server would grow a duplicate record on every
--- sync. It is therefore derived from the anchor, not from a counter or a
--- random value, and `digest` is injected so this stays a pure function
--- (KOReader supplies `require("ffi/sha2").md5`).
---
--- `datetime` is part of the key because KOReader itself treats creation time
--- as immutable identity for an annotation, and two highlights can share a
--- start x-pointer.
function Annotations.id(item, document_hash, digest)
    if type(digest) ~= "function" then return nil end
    local parts = {
        tostring(document_hash or ""),
        tostring(item.datetime or ""),
        type(item.page) == "string" and item.page or "",
        type(item.pos0) == "string" and item.pos0 or "",
        type(item.pos1) == "string" and item.pos1 or "",
        tostring(item.pos0 and item.pos0.x or ""),
        tostring(item.pos0 and item.pos0.y or ""),
        tostring(item.pos1 and item.pos1.x or ""),
        tostring(item.pos1 and item.pos1.y or ""),
        tostring(item.pageno or ""),
    }
    local hex = digest(table.concat(parts, "\30"))
    if type(hex) ~= "string" or hex == "" then return nil end
    local id = "ko-" .. hex
    if #id > Annotations.MAX_ID_BYTES then
        id = id:sub(1, Annotations.MAX_ID_BYTES)
    end
    return id
end

--- Maps one KOReader annotation, or nil plus a reason.
---
--- `opts`: `work_id` (required), `edition_sha`, `document_hash`, `page_count`,
--- `digest` (required), `revisions` (id -> last known server rev), `now`.
function Annotations.one(item, opts)
    if type(item) ~= "table" then return nil, "not-a-table" end
    if type(opts) ~= "table" or type(opts.work_id) ~= "string"
            or opts.work_id == "" then
        return nil, "no-work-id"
    end

    local locator = Annotations.locator(item, opts.document_hash)
    if not locator then return nil, "no-anchor" end

    local id = Annotations.id(item, opts.document_hash, opts.digest)
    if not id then return nil, "no-id" end

    local kind = Annotations.kind(item)
    local revisions = opts.revisions or {}

    local input = {
        id = id,
        base_rev = tonumber(revisions[id]) or 0,
        work_id = opts.work_id,
        edition_sha = opts.edition_sha,
        kind = kind,
        locator = locator,
        progression = Annotations.progression(item, opts.page_count),
        client_ts = Annotations.clientTs(item.datetime, opts.now),
    }

    local excerpt = Annotations.clip(item.text, Annotations.MAX_EXCERPT_BYTES)
    if excerpt then input.excerpt = excerpt end

    if kind == "highlight" then
        -- A KOReader note lives beside the highlighted passage, so it maps to
        -- `body` while the passage stays in `excerpt`.
        local body = Annotations.clip(item.note, Annotations.MAX_BODY_BYTES)
        if body then input.body = body end
        local color = Annotations.color(item.color)
        if color then input.color = color end
    end
    -- A bookmark gets neither: the server rejects a body on a bookmark and a
    -- colour on anything but a highlight.

    return input
end

--- Maps a whole `doc_settings.annotations` array.
---
--- Returns the inputs plus a per-reason skip tally, so a caller can tell the
--- user "3 skipped: no-anchor" instead of silently dropping their notes.
function Annotations.batch(items, opts)
    local inputs, skipped = {}, {}
    if type(items) ~= "table" then return inputs, skipped end
    local seen = {}
    for _, item in ipairs(items) do
        local input, reason = Annotations.one(item, opts)
        if input then
            -- Two identical anchors would be the same record; sending both in
            -- one batch makes the second a guaranteed `conflict`.
            if seen[input.id] then
                skipped["duplicate-anchor"] = (skipped["duplicate-anchor"] or 0) + 1
            else
                seen[input.id] = true
                table.insert(inputs, input)
            end
        else
            skipped[reason or "unknown"] = (skipped[reason or "unknown"] or 0) + 1
        end
    end
    return inputs, skipped
end

--- liseur-sync accepts at most 100 items per request.
Annotations.MAX_BATCH = 100

function Annotations.chunk(inputs, size)
    size = size or Annotations.MAX_BATCH
    local chunks = {}
    for index = 1, #inputs, size do
        local chunk = {}
        for offset = index, math.min(index + size - 1, #inputs) do
            table.insert(chunk, inputs[offset])
        end
        table.insert(chunks, chunk)
    end
    return chunks
end

return Annotations
