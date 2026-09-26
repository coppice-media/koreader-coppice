--[[--
KOReader `doc_settings.annotations` <-> Coppice liseur-sync annotation records.

Pure mapping, no I/O. Wire constraints follow `validate_annotation`:

* `kind` is `highlight`, `note`, or `bookmark`; highlights and bookmarks require
  a locator, notes require a body and may be anchored or unanchored.
* Highlights carry the full KOReader/Liseur color union and drawer style:
  yellow, green, blue, pink, purple, orange, red, olive, cyan, gray; lighten,
  underline, strikeout, or invert. KOReader `underscore` maps to wire
  `underline`. Unsupported values are rejected instead of silently dropped.
* Notes and bookmarks carry neither color nor style. Bookmark carries no body.
* `progression` is in `[0,1]`; IDs, work IDs, excerpt, body, and locator remain
  inside the server's documented byte limits.

KOReader stores one flat table per annotation with `datetime`, `drawer`,
`color`, `text` (highlight excerpt), `note` (user text), `chapter`, `pageno`,
`pageref`, `page`, `pos0`, `pos1`, `pboxes`, and `ext`. `page`/`pos0`/`pos1`
are crengine DOM x-pointers for reflowable books or `{x,y,page}` tables for
paged books; both travel verbatim in the `koreader-annotation` locator. A
Readium locator is anchored only by a unique excerpt/context match in its
chapter/href; unmatched or ambiguous remote annotations stay in the Remote
notes list rather than receiving a guessed position.
]]

local Annotations = {}

Annotations.MAX_ID_BYTES = 64
Annotations.MAX_EXCERPT_BYTES = 1024
Annotations.MAX_BODY_BYTES = 16 * 1024
Annotations.MAX_LOCATOR_BYTES = 16 * 1024
Annotations.LOCATOR_FORMAT = "koreader-annotation"
Annotations.LOCATOR_VERSION = 1

-- KOReader's complete reader palette plus liseur-sync's additional pink token.
-- Tokens are carried verbatim: aliases would lose the user's chosen colour.
local COLOR_MAP = {
    yellow = "yellow",
    green = "green",
    blue = "blue",
    pink = "pink",
    purple = "purple",
    orange = "orange",
    red = "red",
    olive = "olive",
    cyan = "cyan",
    gray = "gray",
}

local DRAWER_MAP = {
    lighten = "lighten",
    underline = "underline",
    underscore = "underline",
    strikeout = "strikeout",
    invert = "invert",
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

-- Seconds since the epoch for a UTC calendar time. Pure arithmetic (days
-- from civil date), so it never depends on the device's time zone or
-- daylight-saving rules the way `os.time` does.
function Annotations.utcEpoch(year, month, day, hour, minute, second)
    local y = month <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local year_of_era = y - era * 400
    local shifted_month = (month + 9) % 12
    local day_of_year = math.floor((153 * shifted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468
    return days * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 + (second or 0)
end

--- KOReader `datetime` ("%Y-%m-%d %H:%M:%S", device local time) -> RFC 3339 UTC.
---
--- `os.time` interprets a table as local time and `os.date("!...")` formats as
--- UTC, so the pair converts without needing to know the offset. A missing or
--- unparseable datetime falls back to `now`, because `client_ts` is required
--- and an annotation with no timestamp is still a real annotation.
--- KOReader datetime or a server RFC 3339 timestamp -> RFC 3339 UTC.
function Annotations.clientTs(datetime, now)
    now = now or os.time()
    if type(datetime) == "string" then
        -- RFC 3339 with an explicit zone (`Z` or `±hh:mm`, optional fraction),
        -- as the server sends it: convert exactly, never as local time.
        local y, mo, d, h, mi, sec, rest =
            datetime:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
        if y then
            local zone = rest:gsub("^%.%d+", "")
            local sign, zone_hours, zone_minutes = zone:match("^([+-])(%d%d):?(%d%d)$")
            if zone == "Z" or sign then
                local offset = sign and (tonumber(zone_hours) * 3600 + tonumber(zone_minutes) * 60)
                    * (sign == "-" and -1 or 1) or 0
                local epoch = Annotations.utcEpoch(tonumber(y), tonumber(mo), tonumber(d),
                    tonumber(h), tonumber(mi), tonumber(sec)) - offset
                return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
            end
        end
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
                -- nil lets mktime decide daylight saving for that date;
                -- `false` shifted every summer timestamp by an hour.
                isdst = nil,
            })
            if epoch then
                return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
            end
        end
    end
    return os.date("!%Y-%m-%dT%H:%M:%SZ", now)
end

local function timestampValue(value)
    if type(value) ~= "string" then return nil end
    local year, month, day, hour, minute, second, tail = value:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return nil end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
    if month < 1 or month > 12 or hour > 23 or minute > 59
            or second > 59 then
        return nil
    end
    local month_days = month == 2 and 28 or
        (month == 4 or month == 6 or month == 9 or month == 11) and 30 or 31
    if month == 2 and (year % 4 == 0
            and (year % 100 ~= 0 or year % 400 == 0)) then
        month_days = 29
    end
    if day < 1 or day > month_days then return nil end

    local zone_length, offset = 1, 0
    if tail:sub(-1) ~= "Z" then
        local sign, offset_hour, offset_minute =
            tail:match("([+-])(%d%d):(%d%d)$")
        if not sign then return nil end
        offset_hour, offset_minute = tonumber(offset_hour),
            tonumber(offset_minute)
        if offset_hour > 23 or offset_minute > 59 then return nil end
        zone_length = 6
        offset = (offset_hour * 60 + offset_minute) * 60
        if sign == "-" then offset = -offset end
    end
    local fraction_text = tail:sub(1, #tail - zone_length)
    local fraction = ""
    if fraction_text ~= "" then
        if not fraction_text:match("^%.%d+$") then return nil end
        fraction = fraction_text:sub(2)
    end

    local adjusted_year = year - (month <= 2 and 1 or 0)
    local era = math.floor(adjusted_year / 400)
    local year_of_era = adjusted_year - era * 400
    local adjusted_month = month + (month > 2 and -3 or 9)
    local day_of_year = math.floor((153 * adjusted_month + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468
    return days * 86400 + hour * 3600 + minute * 60 + second - offset,
        fraction
end

function Annotations.timestampAfter(left, right)
    local left_seconds, left_fraction = timestampValue(left)
    local right_seconds, right_fraction = timestampValue(right)
    if left_seconds == nil or right_seconds == nil then return false end
    if left_seconds ~= right_seconds then return left_seconds > right_seconds end
    for index = 1, math.max(#left_fraction, #right_fraction) do
        local left_digit = left_fraction:byte(index) or 48
        local right_digit = right_fraction:byte(index) or 48
        if left_digit ~= right_digit then return left_digit > right_digit end
    end
    return false
end

function Annotations.recreatedId(previous_id, client_ts, digest)
    if type(previous_id) ~= "string" or type(digest) ~= "function" then
        return nil
    end
    local hash = digest(previous_id .. "\30" .. tostring(client_ts or ""))
    if type(hash) ~= "string" or hash == "" then return nil end
    return ("ko-" .. hash):sub(1, Annotations.MAX_ID_BYTES)
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function sameValue(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not sameValue(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end


function Annotations.drawer(value)
    if type(value) ~= "string" then return nil end
    return DRAWER_MAP[value:lower()]
end

function Annotations.nativeDrawer(value)
    if value == "underline" then return "underscore" end
    return value
end

--- Is this annotation a highlight (KOReader draws it) or a page bookmark?
---
--- `drawer` is the highlight style; notes and page bookmarks have no drawer.
--- KOReader note text without a highlight maps to liseur `kind="note"`.
function Annotations.kind(item)
    if type(item) ~= "table" then return nil end
    if item.drawer then return "highlight" end
    if type(item.note) == "string" and item.note ~= "" then return "note" end
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
    if item.coppice_locator and item.coppice_locator_anchor
            and item.page == item.coppice_locator_anchor.page
            and sameValue(item.pos0, item.coppice_locator_anchor.pos0)
            and sameValue(item.pos1, item.coppice_locator_anchor.pos1) then
        return item.coppice_locator
    end
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

--- A stable KOReader-local identity, independent of a mapped Coppice id.
function Annotations.localId(item, document_hash, digest)
    if type(item) ~= "table" or type(digest) ~= "function" then return nil end
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
    return ("ko-" .. hex):sub(1, Annotations.MAX_ID_BYTES)
end

function Annotations.id(item, document_hash, digest)
    if type(item) == "table" and type(item.coppice_id) == "string"
            and item.coppice_id ~= "" then
        return item.coppice_id
    end
    return Annotations.localId(item, document_hash, digest)
end

--- Whole-publication progression, or nil.
---
--- `pageno` is KOReader's continuous page number; dividing by the page count
--- is the only progression available without asking the document engine, and
--- it is the same quantity Coppice's `reading_heads.progression` holds.
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

    local local_id = Annotations.localId(item, opts.document_hash, opts.digest)
    local id = item.coppice_id
        or (opts.id_map and local_id and opts.id_map[local_id])
        or local_id
    if type(id) ~= "string" or id == "" then return nil, "no-id" end

    local kind = Annotations.kind(item)
    local revisions = opts.revisions or {}
    local previous = revisions[id]
    local revision = type(previous) == "table" and previous.rev or previous
    local client_ts = item.datetime_updated or item.datetime

    local input = {
        id = id,
        work_id = opts.work_id,
        base_rev = tonumber(revision) or 0,
        edition_sha = (not item.datetime_updated and item.coppice_edition_sha)
            or opts.edition_sha,
        kind = kind,
        locator = locator,
        progression = (not item.datetime_updated and item.coppice_progression)
            or Annotations.progression(item, opts.page_count),
        client_ts = (not item.datetime_updated and item.coppice_client_ts)
            or Annotations.clientTs(client_ts, opts.now),
    }

    local excerpt = Annotations.clip(item.text, Annotations.MAX_EXCERPT_BYTES)
    if excerpt then input.excerpt = excerpt end

    if kind == "highlight" then
        local drawer = Annotations.drawer(item.drawer)
        if not drawer then return nil, "unsupported-drawer" end
        input.drawer = drawer
        local body = Annotations.clip(item.note, Annotations.MAX_BODY_BYTES)
        if body then input.body = body end
        if item.color == nil or item.color == "" then
            input.color = ""
        else
            local color = Annotations.color(item.color)
            if not color then return nil, "unsupported-color" end
            input.color = color
        end
    else
        input.color = ""
        input.drawer = ""
        if kind == "note" then
            local body = Annotations.clip(item.note, Annotations.MAX_BODY_BYTES)
            if not body then return nil, "empty-note" end
            input.body = body
        end
    end
    return input
end

--- A clean liseur input view of a server record, without response-only fields.
function Annotations.remoteInput(record)
    if type(record) ~= "table" or type(record.id) ~= "string" then return nil end
    local input = {
        id = record.id,
        work_id = record.work_id,
        base_rev = 0,
        kind = record.kind,
        locator = copy(record.locator),
        progression = record.progression,
        excerpt = record.excerpt,
        color = record.color,
        drawer = record.drawer,
        body = record.body,
        client_ts = record.client_ts,
        edition_sha = record.edition_sha,
    }
    for key, value in pairs(input) do
        if value == nil then input[key] = nil end
    end
    return input
end

--- Converts a live wire record into a native KOReader annotation.
--- `position` is required for non-KOReader locators and contains `start/end`.
function Annotations.fromRemote(record, position, default_drawer)
    if type(record) ~= "table" or type(record.id) ~= "string" then
        return nil, "invalid-record"
    end
    if record.color ~= nil and not Annotations.color(record.color) then
        return nil, "unsupported-color"
    end
    local locator = type(record.locator) == "table" and record.locator or {}
    local native = locator.format == Annotations.LOCATOR_FORMAT
        and locator.version == Annotations.LOCATOR_VERSION
    local wire_drawer = record.drawer or locator.drawer
    if record.drawer ~= nil and not Annotations.drawer(record.drawer) then
        return nil, "unsupported-drawer"
    end
    if record.kind == "highlight" and wire_drawer
            and not Annotations.drawer(wire_drawer) then
        return nil, "unsupported-drawer"
    end
    local start = native and (locator.page or locator.pos0)
        or position and position.start
    local finish = native and locator.pos1 or position and position.finish
    if start == nil then return nil, "unanchored" end
    local drawer = native and locator.drawer or Annotations.nativeDrawer(wire_drawer)
    if record.kind == "highlight" and not drawer then
        drawer = default_drawer or "lighten"
    end
    local remote_text = type(locator.text) == "table" and locator.text or {}
    local created_at = type(record.client_ts) == "string"
        and record.client_ts:gsub("T", " "):gsub("Z$", "") or nil
    local item = {
        datetime = created_at,
        coppice_client_ts = record.client_ts,
        coppice_progression = record.progression,
        coppice_edition_sha = record.edition_sha,
        page = start,
        pos0 = native and copy(locator.pos0) or start,
        pos1 = native and copy(locator.pos1) or finish,
        pageno = native and locator.pageno or nil,
        chapter = native and locator.chapter or position and position.chapter,
        drawer = drawer,
        color = record.color,
        text = record.excerpt or remote_text.highlight,
        note = record.body,
        ext = native and copy(locator.ext) or nil,
        coppice_id = record.id,
        coppice_remote = true,
        coppice_locator = copy(locator),
        coppice_locator_anchor = {
            page = start,
            pos0 = native and copy(locator.pos0) or start,
            pos1 = native and copy(locator.pos1) or finish,
        },
    }
    return item
end

local function normalizeText(value)
    if type(value) ~= "string" then return "" end
    return value:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Context comparison ignores punctuation and quote style: KOReader search
--- context and Readium locator text differ in punctuation and length.
local function contextWords(value)
    return (normalizeText(value):gsub("[^%w%s]", " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", ""))
end

--- True when the shorter context is the suffix (before) or prefix (after)
--- of the longer one. KOReader returns a few words of context while Readium
--- locators carry a fixed character window, so only the overlap is compared.
local function contextAgrees(candidate, expected, is_before)
    if candidate == "" or expected == "" then return true end
    local short, long = candidate, expected
    if #short > #long then short, long = long, short end
    if is_before then
        return long:sub(#long - #short + 1) == short
    end
    return long:sub(1, #short) == short
end

--- Selects exactly one text-search hit for a remote excerpt. The href/chapter
--- hints only exclude hits that report their own href/chapter (KOReader TOC
--- entries usually carry neither). A single in-scope exact hit anchors on its
--- own; surrounding context only breaks ties, because Readium context crosses
--- spine-item boundaries that KOReader search context does not. Hits that
--- remain ambiguous are rejected rather than guessed.
function Annotations.anchorCandidates(candidates, locator, excerpt)
    locator = type(locator) == "table" and locator or {}
    local expected = normalizeText(excerpt)
    if expected == "" then return nil, "no-excerpt" end
    local text = type(locator.text) == "table" and locator.text or {}
    local before = contextWords(text.before)
    local after = contextWords(text.after)
    local requested_href = locator.href
    local requested_chapter = locator.chapter
        and normalizeText(locator.chapter) or nil
    local matches = {}
    for _unused, candidate in ipairs(candidates or {}) do
        local in_scope = true
        if requested_href and candidate.href then
            in_scope = candidate.href == requested_href
        end
        if requested_chapter and candidate.chapter then
            in_scope = in_scope
                and normalizeText(candidate.chapter) == requested_chapter
        end
        if in_scope
                and normalizeText(candidate.text or candidate.excerpt) == expected
                and candidate.start ~= nil and candidate.finish ~= nil then
            table.insert(matches, candidate)
        end
    end
    if #matches > 1 then
        local agreeing = {}
        for _unused, candidate in ipairs(matches) do
            if contextAgrees(contextWords(candidate.before), before, true)
                    and contextAgrees(contextWords(candidate.after), after, false) then
                table.insert(agreeing, candidate)
            end
        end
        matches = agreeing
        if #matches == 0 then return nil, "ambiguous" end
    end
    if #matches == 1 then
        return { start = matches[1].start, finish = matches[1].finish,
            chapter = matches[1].chapter, href = matches[1].href }
    end
    return nil, #matches == 0 and "not-found" or "ambiguous"
end

--- Builds the KOReader item inputs as pure functions, for host-side checks.

local function canonical(value, seen)
    local kind = type(value)
    if kind == "nil" then return "z" end
    if kind == "boolean" then return value and "b1" or "b0" end
    if kind == "string" then return "s" .. #value .. ":" .. value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil
        end
        return "n" .. string.format("%.17g", value) .. ";"
    end
    if kind ~= "table" or seen[value] then return nil end

    local keys = {}
    for key in pairs(value) do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number"
                and key_type ~= "boolean" then
            return nil
        end
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local left_type, right_type = type(left), type(right)
        if left_type ~= right_type then return left_type < right_type end
        return tostring(left) < tostring(right)
    end)

    seen[value] = true
    local parts = { "t", tostring(#keys), ":" }
    for _unused, key in ipairs(keys) do
        local encoded_key = canonical(key, seen)
        local encoded_value = canonical(value[key], seen)
        if not encoded_key or not encoded_value then
            seen[value] = nil
            return nil
        end
        parts[#parts + 1] = encoded_key
        parts[#parts + 1] = encoded_value
    end
    seen[value] = nil
    return table.concat(parts)
end

--- Stable digest of the payload excluding only compare-and-set `base_rev`.
function Annotations.signature(input, digest)
    if type(input) ~= "table" or type(digest) ~= "function" then return nil end
    local payload = {}
    for key, value in pairs(input) do
        if key ~= "base_rev"
                and not ((key == "color" or key == "drawer") and value == "") then
            payload[key] = value
        end
    end
    local encoded = canonical(payload, {})
    if not encoded then return nil end
    local ok, signature = pcall(digest, encoded)
    if not ok or type(signature) ~= "string" or signature == "" then return nil end
    return signature
end

--- Removes payloads already acknowledged at their current local revision.
---
--- Legacy revision-only records are sent once; after the server acknowledges
--- them the signature is saved and later identical exports become no-ops.
function Annotations.filterUnchanged(inputs, revisions, digest)
    local pending, signatures, unchanged = {}, {}, 0
    revisions = type(revisions) == "table" and revisions or {}
    for _unused, input in ipairs(inputs or {}) do
        local signature = Annotations.signature(input, digest)
        local previous = revisions[input.id]
        if signature then signatures[input.id] = signature end
        if signature and type(previous) == "table"
                and previous.signature == signature then
            unchanged = unchanged + 1
        else
            pending[#pending + 1] = input
        end
    end
    return pending, signatures, unchanged
end

--- Maps a whole `doc_settings.annotations` array.
---
--- Returns the inputs plus a per-reason skip tally, so a caller can tell the
--- user "3 skipped: no-anchor" instead of silently dropping their notes.
function Annotations.batch(items, opts)
    local inputs, skipped = {}, {}
    if type(items) ~= "table" then return inputs, skipped end
    local seen = {}
    for _unused, item in ipairs(items) do
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
