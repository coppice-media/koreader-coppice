--[[--
Pure helpers for the KOReader cover browser: catalog mapping, screen layout,
paging, safe thumbnail URLs/cache names, and deterministic cache eviction.
No KOReader modules, network calls, or filesystem access live here.
]]

local Url = require("coppice_url")
local Annotations = require("coppice_annotations")
local _ = require("gettext")

local Catalog = {}
local READER_EXTENSIONS = {
    ["azw3"] = true, ["cbt"] = true, ["cbr"] = true,
    ["cbz"] = true, ["djvu"] = true, ["epub"] = true, ["fb2"] = true,
    ["fb2.zip"] = true, ["mobi"] = true, ["pdf"] = true, ["txt"] = true,
    ["xhtml"] = true, ["zip"] = true,
}

function Catalog.readerExtension(value)
    if type(value) ~= "string" then return nil end
    local extension = value:lower():gsub("^%.", "")
    return READER_EXTENSIONS[extension] and extension or nil
end

-- Formats Coppice serves as audiobooks. KOReader cannot play audio, so these
-- are never downloaded; the book page points at a readable edition instead.
local AUDIO_EXTENSIONS = {
    ["aac"] = true, ["flac"] = true, ["m4a"] = true, ["m4b"] = true,
    ["mp3"] = true, ["ogg"] = true, ["opus"] = true, ["wav"] = true,
}

Catalog.AUDIO_EXTENSION_LIST = {}
for extension in pairs(AUDIO_EXTENSIONS) do
    Catalog.AUDIO_EXTENSION_LIST[#Catalog.AUDIO_EXTENSION_LIST + 1] = extension
end
table.sort(Catalog.AUDIO_EXTENSION_LIST)

function Catalog.isAudiobook(item)
    if type(item) ~= "table" then return false end
    if type(item.audio) == "table" then return true end
    local extension = type(item.extension) == "string"
        and item.extension:lower():gsub("^%.", "") or ""
    return AUDIO_EXTENSIONS[extension] == true
end

-- The first confirmed edition KOReader can open, from `editions`.
function Catalog.readableEdition(editions)
    for _unused, edition in ipairs(type(editions) == "table" and editions or {}) do
        local extension = type(edition) == "table" and Catalog.readerExtension(edition.extension)
        if extension and edition.id then
            return {
                id = edition.id,
                title = edition.resolvedName or edition.name or "(untitled)",
                extension = extension,
                kind = "book",
                cover_kind = "media",
            }
        end
    end
    return nil
end

local function listText(value)
    if type(value) == "string" then return value end
    if type(value) ~= "table" then return nil end
    local result = {}
    for _unused, item in ipairs(value) do
        if type(item) == "string" and item ~= "" then
            result[#result + 1] = item
        end
    end
    if #result == 0 then return nil end
    return table.concat(result, ", ")
end

function Catalog.progressPercent(value)
    local number = tonumber(value)
    if not number then return nil end
    -- GraphQL Decimal and the REST continue route both use 0..=1.
    if number > 1 then number = number / 100 end
    return math.max(0, math.min(100, math.floor(number * 100 + 0.5)))
end

function Catalog.media(item)
    if type(item) ~= "table" then return nil end
    local metadata = type(item.metadata) == "table" and item.metadata or {}
    local series = type(item.series) == "table" and item.series or {}
    local progress = type(item.readProgress) == "table" and item.readProgress or {}
    local pages = tonumber(metadata.pageCount) or tonumber(item.pages)
    if pages and pages <= 0 then pages = nil end
    local tags = {}
    for _unused, tag in ipairs(type(item.tags) == "table" and item.tags or {}) do
        local name = type(tag) == "table" and tag.name or tag
        if type(name) == "string" and name ~= "" then tags[#tags + 1] = name end
    end
    return {
        is_audiobook = Catalog.isAudiobook(item),
        id = item.id,
        title = metadata.title or item.resolvedName or item.name or "(untitled)",
        authors = listText(metadata.writers),
        year = tonumber(metadata.year),
        publisher = metadata.publisher,
        pages = pages,
        summary = metadata.summary,
        tags = tags,
        extension = Catalog.readerExtension(item.extension),
        series_id = item.seriesId or series.id,
        series = series.resolvedName or series.name or metadata.series,
        status = item.status,
        progression = Catalog.progressPercent(progress.percentageCompleted),
        page = tonumber(progress.page),
        position_ms = tonumber(progress.positionMs),
        created_at = item.createdAt,
        cover_kind = "media",
    }
end

function Catalog.continueItem(item)
    if type(item) ~= "table" then return nil end
    local mapped = Catalog.media(item)
    if not mapped then
        mapped = {
            id = item.mediaId,
            title = item.title or item.name or "(untitled)",
            authors = item.authors,
            extension = Catalog.readerExtension(item.extension),
            series_id = item.seriesId,
            series = item.seriesName,
            cover_kind = "media",
        }
    end
    mapped.id = item.mediaId or mapped.id
    -- `title` is the server's display title (metadata title, else file
    -- name); `name` alone can be a folder like "Enders Game (MP3)".
    mapped.title = item.title or item.name or mapped.title
    mapped.extension = Catalog.readerExtension(item.extension) or mapped.extension
    mapped.is_audiobook = mapped.is_audiobook or Catalog.isAudiobook(item)
    mapped.progression = Catalog.progressPercent(item.progression)
    mapped.page = tonumber(item.page) or mapped.page
    mapped.pages = tonumber(item.pages) or mapped.pages
    mapped.position_ms = tonumber(item.positionMs) or mapped.position_ms
    mapped.koreader_hash = item.koreaderHash
    return mapped
end

function Catalog.series(item)
    if type(item) ~= "table" then return nil end
    return {
        id = item.id,
        title = item.resolvedName or item.name or "(untitled)",
        summary = item.resolvedDescription or item.description,
        cover_kind = "series",
        created_at = item.createdAt,
        book_count = tonumber(item.mediaCount),
        progression = Catalog.progressPercent(item.percentageCompleted),
    }
end

function Catalog.author(item)
    if type(item) ~= "table" then return nil end
    return {
        id = item.name,
        title = item.name or "(unknown author)",
        kind = "author",
        cover_kind = "placeholder",
    }
end

function Catalog.page(items, page, page_size)
    items = type(items) == "table" and items or {}
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    local total = #items
    local page_count = math.max(1, math.ceil(total / page_size))
    page = math.max(1, math.min(page_count, math.floor(tonumber(page) or 1)))
    local first = (page - 1) * page_size + 1
    local result = {}
    for index = first, math.min(total, first + page_size - 1) do
        result[#result + 1] = items[index]
    end
    return result, page, page_count
end

-- Oversized GraphQL fixtures and server responses must never turn into one
-- widget per library book. Normal server pages are left untouched.
function Catalog.visiblePage(items, page, page_size, force_page)
    items = type(items) == "table" and items or {}
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    if force_page or #items > page_size then
        return Catalog.page(items, page, page_size)
    end
    return items, math.max(1, math.floor(tonumber(page) or 1)), 1
end

function Catalog.continueTapAction(item, is_local_file)
    if is_local_file and type(item) == "table"
            and type(item.local_path) == "string" and item.local_path ~= "" then
        return "open"
    end
    return "detail"
end

function Catalog.searchRequest(query, limit)
    return [[query($query: String!, $limit: Int!) {
        searchBooks(query: $query, limit: $limit) { mediaId title authors }
    }]], {
        query = query,
        limit = math.max(1, math.floor(tonumber(limit) or 50)),
    }
end
function Catalog.statisticsQuery()
    return [[
        SELECT day,
               COUNT(*) AS pages,
               COALESCE(SUM(duration), 0) AS seconds,
               CAST(julianday(date('now', 'localtime')) - julianday(day) AS INTEGER) AS days_ago
        FROM (
            SELECT date(start_time, 'unixepoch', 'localtime') AS day,
                   id_book, page, SUM(duration) AS duration
            FROM page_stat
            GROUP BY day, id_book, page
        )
        GROUP BY day
        ORDER BY day DESC
    ]]
end

function Catalog.readingStats(rows)
    local days = {}
    for _unused, row in ipairs(type(rows) == "table" and rows or {}) do
        local offset = tonumber(row.days_ago)
        if offset and offset >= 0 then
            days[math.floor(offset)] = {
                pages = tonumber(row.pages) or 0,
                seconds = tonumber(row.seconds) or 0,
            }
        end
    end
    local today = days[0] or { pages = 0, seconds = 0 }
    local week_pages, week_seconds = 0, 0
    for offset = 0, 6 do
        local day = days[offset]
        if day then
            week_pages = week_pages + day.pages
            week_seconds = week_seconds + day.seconds
        end
    end
    local streak_start = days[0] and 0 or 1
    local streak_days = 0
    while days[streak_start + streak_days] do
        streak_days = streak_days + 1
    end
    return {
        -- False until KOReader's statistics hold any reading at all.
        has_data = next(days) ~= nil,
        today_pages = today.pages,
        today_minutes = math.floor(today.seconds / 60 + 0.5),
        week_pages = week_pages,
        week_minutes = math.floor(week_seconds / 60 + 0.5),
        streak_days = streak_days,
    }
end

function Catalog.truncateText(value, max_bytes)
    if type(value) ~= "string" or value == "" then return "" end
    max_bytes = math.max(4, math.floor(tonumber(max_bytes) or 256))
    if #value <= max_bytes then return value end
    return (Annotations.clip(value, max_bytes - 3) or "") .. "…"
end

function Catalog.recentAnnotations(items, limit)
    local sorted = {}
    for _unused, item in ipairs(type(items) == "table" and items or {}) do
        if type(item) == "table" then
            local note = item.body or item.note
            local kind = item.kind or (item.drawer and "highlight"
                or (type(note) == "string" and note ~= "" and "note" or "bookmark"))
            if kind == "highlight" or kind == "note" then
                local entry = {}
                for key, value in pairs(item) do entry[key] = value end
                local timestamp = item.updated_at or item.datetime_updated
                    or item.coppice_client_ts or item.client_ts or item.datetime
                entry.updated_at = type(timestamp) == "string"
                    and Annotations.clientTs(timestamp, 0) or ""
                entry.excerpt = Catalog.truncateText(item.excerpt or item.text, 360)
                entry.body = Catalog.truncateText(note, 180)
                entry.kind = kind
                sorted[#sorted + 1] = entry
            end
        end
    end
    table.sort(sorted, function(left, right)
        if left.updated_at == right.updated_at then
            return tostring(left.id or left.coppice_id or "")
                < tostring(right.id or right.coppice_id or "")
        end
        return left.updated_at > right.updated_at
    end)
    local result = {}
    local count = math.min(#sorted, math.max(0, math.floor(tonumber(limit) or 4)))
    for index = 1, count do result[index] = sorted[index] end
    return result
end

local RECENT_PAGE_SIZE = 4

function Catalog.pageCount(total, page_size)
    page_size = math.max(1, math.floor(tonumber(page_size) or 1))
    return math.max(1, math.ceil((tonumber(total) or 0) / page_size))
end

function Catalog.recentRow(items, page, page_size)
    return Catalog.page(items, page, page_size or RECENT_PAGE_SIZE)
end

-- Reading time for the stat strip: "45m", "3h", "3h 10m".
function Catalog.durationLabel(minutes)
    minutes = math.max(0, math.floor(tonumber(minutes) or 0))
    if minutes < 60 then return tostring(minutes) .. "m" end
    local hours, rest = math.floor(minutes / 60), minutes % 60
    if rest == 0 then return tostring(hours) .. "h" end
    return string.format("%dh %dm", hours, rest)
end

Catalog.utcEpoch = Annotations.utcEpoch

function Catalog.relativeTime(timestamp, now)
    if type(timestamp) ~= "string" or timestamp == "" then return "" end
    local year, month, day, hour, minute, second, rest =
        timestamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then return timestamp:sub(1, 10) end
    local parts = { year = tonumber(year), month = tonumber(month), day = tonumber(day),
        hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second) }
    local epoch
    -- `rest` is an optional fraction then `Z`, `±hh:mm`, `±hhmm`, or nothing
    -- (a zone-less stamp is taken as local time).
    local zone = rest:gsub("^%.%d+", "")
    local sign, zone_hours, zone_minutes = zone:match("^([+-])(%d%d):?(%d%d)$")
    if zone == "Z" or sign then
        local offset = 0
        if sign then
            offset = (tonumber(zone_hours) * 3600 + tonumber(zone_minutes) * 60)
                * (sign == "-" and -1 or 1)
        end
        epoch = Catalog.utcEpoch(parts.year, parts.month, parts.day,
            parts.hour, parts.min, parts.sec) - offset
    else
        epoch = os.time(parts)
    end
    local age = math.max(0, (tonumber(now) or os.time()) - epoch)
    if age < 60 then return _("just now") end
    if age < 3600 then return tostring(math.floor(age / 60)) .. "m ago" end
    if age < 86400 then return tostring(math.floor(age / 3600)) .. "h ago" end
    if age < 7 * 86400 then return tostring(math.floor(age / 86400)) .. "d ago" end
    return os.date("%Y-%m-%d", epoch)
end

function Catalog.annotationSource(record)
    record = type(record) == "table" and record or {}
    local locator = type(record.locator) == "table" and record.locator or {}
    local device = tostring(record.device_id or ""):lower()
    local format = tostring(locator.format or ""):lower()
    if format == Annotations.LOCATOR_FORMAT or device:find("koreader", 1, true) then
        return "KOReader"
    end
    if format:find("readium", 1, true) or format:find("home", 1, true)
            or device:find("readium", 1, true) or device:find("home", 1, true) then
        return "Home/Readium"
    end
    return "Liseur"
end

local SOURCE_LABELS = {
    KOBO = "Kobo", KOREADER = "KOReader", COPPICE = "Coppice", LISEUR = "Liseur",
    WEB = "Home", KOMELIA = "Komelia", MIHON = "Mihon", CROSSPOINT = "CrossPoint",
    ABS = "Audiobookshelf", KAVITA = "Kavita", OPDS = "OPDS", API = "API",
}

-- The newest highlights and notes across every book and source, newest
-- change first. Bookmarks are left out: they carry no passage to show.
function Catalog.recentAnnotationsRequest(limit, page)
    limit = math.max(1, math.min(20, math.floor(tonumber(limit) or 4)))
    page = math.max(1, math.floor(tonumber(page) or 1))
    return [[query($pagination: OffsetPagination) {
        annotations(order: RECENT, pagination: $pagination,
                    filter: { kind: [HIGHLIGHT, NOTE] }) {
            total
            items {
                id kind source sourceDeviceName color excerpt note
                page progression chapterTitle createdAt updatedAt
                book { mediaId title koreaderHash }
            }
        }
    }]], { pagination = { page = page, pageSize = limit } }
end

-- GraphQL routes Liseur-lane notes as `liseur-sync:<user id>:<note id>` so
-- Home edits hit the right lane; KOReader stores the bare note id in
-- `coppice_id`, so matching and de-duplication use the bare id.
function Catalog.bareAnnotationId(id)
    if id == nil then return nil end
    id = tostring(id)
    return id:match("^liseur%-sync:[^:]+:(.+)$") or id
end

-- One server annotation as a Home "Recent highlights & notes" item.
function Catalog.serverAnnotation(entry)
    if type(entry) ~= "table" or not entry.id then return nil end
    local book = type(entry.book) == "table" and entry.book or {}
    local kind = tostring(entry.kind or "HIGHLIGHT"):lower()
    local device = type(entry.sourceDeviceName) == "string" and entry.sourceDeviceName ~= ""
        and entry.sourceDeviceName or nil
    local source
    if tostring(entry.source or "") == "COPPICE" and device then
        -- Coppice's own reader clients (this KOReader plugin, NickelCoppice)
        -- share one kind; their device name says which reader it was.
        source = device
    else
        source = SOURCE_LABELS[tostring(entry.source or "")]
            or (entry.source and tostring(entry.source)) or "Coppice"
        if device and device ~= source then source = source .. " · " .. device end
    end
    return {
        id = Catalog.bareAnnotationId(entry.id),
        kind = kind,
        book_id = book.mediaId and tostring(book.mediaId) or nil,
        book_hash = type(book.koreaderHash) == "string" and book.koreaderHash ~= ""
            and book.koreaderHash or nil,
        title = book.title,
        book_title = book.title,
        excerpt = entry.excerpt,
        body = entry.note,
        color = entry.color,
        source = source,
        page = tonumber(entry.page),
        progression = tonumber(entry.progression),
        chapter = entry.chapterTitle,
        updated_at = entry.updatedAt or entry.createdAt,
    }
end

function Catalog.isPositionedAnnotation(item)
    if type(item) ~= "table" then return false end
    local locator = type(item.locator) == "table" and item.locator or {}
    return item.page ~= nil or item.pos0 ~= nil
        or locator.page ~= nil or locator.pos0 ~= nil
end

-- Cover-grid geometry for a screen. `scale` is the device's density factor
-- (KOReader `Screen:scaleBySize(1)`), so a tile keeps a minimum *physical*
-- width: a narrow high-density phone gets 2-3 columns, a Kobo or desktop 4.
-- Rows are as many 2:3 covers as fit under the top and bottom bars.
function Catalog.layout(width, height, scale)
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or 1))
    scale = math.max(0.5, tonumber(scale) or 1)
    local function dp(value) return math.floor(value * scale + 0.5) end
    local margin, gap, min_tile = dp(12), dp(10), dp(110)
    local columns = math.max(2, math.min(4,
        math.floor((width - 2 * margin + gap) / (min_tile + gap))))
    local tile_width = math.floor((width - 2 * margin - gap * (columns - 1)) / columns)
    local cover_width = math.max(1, tile_width - dp(10))
    local cover_height = math.max(dp(90), math.floor(cover_width * 1.5))
    -- Top bar (title, subtitle, status) and bottom bar (page controls).
    local header, footer = dp(118), dp(72)
    local available = math.max(cover_height, height - header - footer - 2 * margin)
    local rows = math.max(1, math.min(6,
        math.floor((available + gap) / (cover_height + gap))))
    return {
        columns = columns,
        rows = rows,
        page_size = columns * rows,
        tile_width = tile_width,
        cover_width = cover_width,
        cover_height = cover_height,
        gap = gap,
        margin = margin,
        header_height = header,
        footer_height = footer,
    }
end


function Catalog.pageLabel(total, kind, sort_label)
    return tostring(tonumber(total) or 0) .. " " .. (kind or "books")
        .. " · Sort: " .. (sort_label or "Title (A–Z)")
end

function Catalog.coverUrl(base, item)
    if type(item) ~= "table" or type(item.id) ~= "string" or item.id == "" then
        return nil
    end
    if item.cover_kind ~= nil and item.cover_kind ~= "media"
            and item.cover_kind ~= "series" then
        return nil
    end
    local kind = item.cover_kind == "series" and "series" or "media"
    return Url.api(base, "/" .. kind .. "/" .. Url.escape(item.id) .. "/thumbnail")
end

function Catalog.cacheFileName(kind, id)
    if type(id) ~= "string" or id == "" then return nil end
    if kind ~= "media" and kind ~= "series" then return nil end
    local safe = id:gsub("[^A-Za-z0-9_-]", "_")
    if safe == "" then return nil end
    return (kind == "series" and "series-" or "media-") .. safe .. ".jpg"
end

function Catalog.cacheEvictions(entries, max_bytes)
    max_bytes = math.max(0, tonumber(max_bytes) or 0)
    local sorted = {}
    local total = 0
    for _unused, entry in ipairs(type(entries) == "table" and entries or {}) do
        local size = math.max(0, tonumber(entry.size) or 0)
        total = total + size
        sorted[#sorted + 1] = {
            name = tostring(entry.name or entry.path or ""),
            path = entry.path,
            size = size,
            modified = tonumber(entry.modified) or 0,
        }
    end
    table.sort(sorted, function(left, right)
        if left.modified ~= right.modified then return left.modified < right.modified end
        return left.name < right.name
    end)
    local evictions = {}
    local index = 1
    while total > max_bytes and sorted[index] do
        local entry = sorted[index]
        evictions[#evictions + 1] = entry.path or entry.name
        total = total - entry.size
        index = index + 1
    end
    return evictions, total
end

return Catalog
