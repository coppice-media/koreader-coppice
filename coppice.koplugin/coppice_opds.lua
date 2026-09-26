--[[--
OPDS 2.0 feed -> flat browser rows.

Pure table-to-table mapping, no I/O. Coppice's OPDS 2.0 feeds are Readium-style
JSON: a feed has `metadata`, `links`, `navigation`, `publications`, and
`groups`, where a group is a titled sub-feed that carries its own `navigation`
or `publications` (the catalogue root is three groups: Libraries, Latest Books,
Keep Reading).

A publication's position is *not* in the publication: it is a
`http://www.cantook.com/api/progression` link. That is exactly why the
dashboard uses `/api/v2/reading/continue` instead of walking this feed.
]]

local Url = require("coppice_url")

local Opds = {}

Opds.REL_SELF = "self"
Opds.REL_NEXT = "next"
Opds.REL_PREVIOUS = "previous"
Opds.REL_ACQUISITION = "http://opds-spec.org/acquisition"
Opds.REL_PROGRESSION = "http://www.cantook.com/api/progression"
Opds.REL_IMAGE = "http://opds-spec.org/image"
Opds.REL_THUMBNAIL = "http://opds-spec.org/image/thumbnail"

--- The file extension Coppice's acquisition media types imply.
---
--- Only formats KOReader can open are mapped. An unmapped type keeps the
--- book listed but marks it undownloadable, which is honest: a `.m4b`
--- audiobook is a real Coppice book and not a thing this plugin can hand to a
--- reader engine.
local EXTENSION_BY_TYPE = {
    ["application/epub+zip"] = "epub",
    ["application/pdf"] = "pdf",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/vnd.comicbook-rar"] = "cbr",
    ["application/x-cbz"] = "cbz",
    ["application/x-cbr"] = "cbr",
    ["application/zip"] = "zip",
    ["application/vnd.rar"] = "cbr",
    ["text/plain"] = "txt",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/vnd.amazon.ebook"] = "azw3",
    ["application/fb2+zip"] = "fb2.zip",
    ["application/x-fictionbook+xml"] = "fb2",
    ["application/xhtml+xml"] = "xhtml",
    ["application/x-cbt"] = "cbt",
    ["application/djvu"] = "djvu",
    ["image/vnd.djvu"] = "djvu",
}

function Opds.extensionForType(media_type)
    if type(media_type) ~= "string" then return nil end
    -- Media types can carry parameters (`; charset=`); the base type decides.
    local base = media_type:gsub(";.*$", ""):gsub("%s+", ""):lower()
    return EXTENSION_BY_TYPE[base]
end

--- `rel` is a string in some feeds and an array in others (Readium allows
--- both); normalize to a predicate.
local function hasRel(link, rel)
    local value = link.rel
    if value == nil then return false end
    if type(value) == "string" then return value == rel end
    if type(value) == "table" then
        for _unused, item in ipairs(value) do
            if item == rel then return true end
        end
    end
    return false
end

local function findLink(links, rel)
    if type(links) ~= "table" then return nil end
    for _unused, link in ipairs(links) do
        if type(link) == "table" and hasRel(link, rel) then return link end
    end
    return nil
end

--- The Coppice media id, taken from a `/opds/v2.0/books/<id>` style href.
---
--- The id is what every other surface keys on: `/api/v2/media/{id}/file`,
--- `POST /v1/books/{id}/resolve`. Deriving it from the feed avoids a second
--- request just to learn an identifier the feed already told us.
function Opds.bookId(href)
    if type(href) ~= "string" then return nil end
    local id = href:match("/opds/v2%.0/books/([^/%?#]+)")
    if id then return id end
    return href:match("/api/v2/media/([^/%?#]+)")
end

local function authorNames(metadata)
    local author = metadata and metadata.author
    if author == nil then return nil end
    if type(author) == "string" then return author end
    if type(author) ~= "table" then return nil end
    -- A single contributor object, not a list.
    if author.name then return author.name end
    local names = {}
    for _unused, entry in ipairs(author) do
        if type(entry) == "string" then
            table.insert(names, entry)
        elseif type(entry) == "table" and entry.name then
            table.insert(names, entry.name)
        end
    end
    if #names == 0 then return nil end
    return table.concat(names, ", ")
end

Opds.authorNames = authorNames

--- One publication as the browser needs it.
---
--- `base` re-bases every href (see `Url.rebase`). `download` is nil when the
--- publication has no single acquisition this plugin can fetch: a multi-file
--- audiobook advertises one acquisition *per track*, which is a playlist, not
--- a book file.
function Opds.publication(base, pub)
    if type(pub) ~= "table" then return nil end
    local metadata = pub.metadata or {}
    local links = pub.links or {}

    local acquisitions = {}
    for _unused, link in ipairs(links) do
        if type(link) == "table" and hasRel(link, Opds.REL_ACQUISITION) and link.href then
            table.insert(acquisitions, link)
        end
    end

    local self_link = findLink(links, Opds.REL_SELF)
    local id = Opds.bookId(self_link and self_link.href or "")
    if not id and #acquisitions > 0 then
        id = Opds.bookId(acquisitions[1].href)
    end

    local download, extension
    if #acquisitions == 1 then
        download = Url.rebase(base, acquisitions[1].href)
        extension = Opds.extensionForType(acquisitions[1].type)
    end

    local series, series_position
    local belongs_to = metadata.belongsTo or metadata.belongs_to
    if type(belongs_to) == "table" and type(belongs_to.series) == "table" then
        series = belongs_to.series.name
        series_position = belongs_to.series.position
    end

    local image = findLink(pub.images, Opds.REL_THUMBNAIL)
        or findLink(pub.images, Opds.REL_IMAGE)
    if not image and type(pub.images) == "table" then
        image = pub.images[1]
    end

    return {
        id = id,
        title = metadata.title or "(untitled)",
        author = authorNames(metadata),
        series = series,
        series_position = series_position,
        description = metadata.description,
        media_type = #acquisitions == 1 and acquisitions[1].type or nil,
        extension = extension,
        track_count = #acquisitions > 1 and #acquisitions or nil,
        download_url = download,
        cover_url = image and image.href and Url.rebase(base, image.href) or nil,
        progression_url = (function()
            local link = findLink(links, Opds.REL_PROGRESSION)
            return link and link.href and Url.rebase(base, link.href) or nil
        end)(),
    }
end

--- Navigation entries (a library, a series, a sub-catalogue).
function Opds.navigation(base, feed)
    local rows = {}
    if type(feed) ~= "table" or type(feed.navigation) ~= "table" then return rows end
    for _unused, entry in ipairs(feed.navigation) do
        if type(entry) == "table" and entry.href then
            table.insert(rows, {
                title = (entry.title or entry.metadata and entry.metadata.title)
                    or "(untitled)",
                url = Url.rebase(base, entry.href),
                media_type = entry.type,
            })
        end
    end
    return rows
end

function Opds.publications(base, feed)
    local rows = {}
    if type(feed) ~= "table" or type(feed.publications) ~= "table" then return rows end
    for _unused, pub in ipairs(feed.publications) do
        local row = Opds.publication(base, pub)
        if row then table.insert(rows, row) end
    end
    return rows
end

--- The feed's groups, each already flattened into navigation/publication rows.
function Opds.groups(base, feed)
    local rows = {}
    if type(feed) ~= "table" or type(feed.groups) ~= "table" then return rows end
    for _unused, group in ipairs(feed.groups) do
        if type(group) == "table" then
            local metadata = group.metadata or {}
            local self_link = findLink(group.links, Opds.REL_SELF)
            table.insert(rows, {
                title = metadata.title or "(untitled)",
                url = self_link and self_link.href
                    and Url.rebase(base, self_link.href) or nil,
                navigation = Opds.navigation(base, group),
                publications = Opds.publications(base, group),
            })
        end
    end
    return rows
end

--- Paging links, re-based. Coppice emits `next` unconditionally, so a caller
--- must still notice an empty page rather than trusting `next` to disappear.
function Opds.paging(base, feed)
    if type(feed) ~= "table" then return {} end
    local function url(rel)
        local link = findLink(feed.links, rel)
        return link and link.href and Url.rebase(base, link.href) or nil
    end
    local metadata = feed.metadata or {}
    return {
        self_url = url(Opds.REL_SELF),
        next_url = url(Opds.REL_NEXT),
        previous_url = url(Opds.REL_PREVIOUS),
        total = tonumber(metadata.numberOfItems),
        per_page = tonumber(metadata.itemsPerPage),
        page = tonumber(metadata.currentPage),
    }
end

--- The whole feed as the browser consumes it.
function Opds.feed(base, body)
    return {
        title = body and body.metadata and body.metadata.title or nil,
        navigation = Opds.navigation(base, body),
        publications = Opds.publications(base, body),
        groups = Opds.groups(base, body),
        paging = Opds.paging(base, body),
    }
end

local ILLEGAL_FILENAME_CHARS = '[/\\%?%%%*:|"<>%c]'

--- A device-safe filename for a downloaded book.
---
--- FAT32 on a Kobo/Kindle rejects `\\ / : * ? " < > |`; a title can contain
--- any of them. The Coppice media id is appended so two books with the same
--- title in different series cannot overwrite each other.
function Opds.filename(pub)
    local title = tostring(pub.title or "book")
    title = title:gsub(ILLEGAL_FILENAME_CHARS, "_")
    title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #title > 96 then title = title:sub(1, 96) end
    if title == "" then title = "book" end
    local suffix = pub.id and ("-" .. tostring(pub.id):sub(1, 8)) or ""
    local extension = pub.extension and ("." .. pub.extension) or ""
    return title .. suffix .. extension
end

return Opds
