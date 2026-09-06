--[[--
The Stump browser: a `Menu` over the dashboard, the OPDS 2.0 catalogue, and
book downloads.

Navigation is a path stack, the same shape KOReader's own OPDS browser uses,
so Back pops one level and re-fetches instead of rebuilding from the root.

Two different surfaces feed this one list, for one reason: OPDS 2.0 names the
books but carries a position only as a per-publication *link*, so the
"Continue reading" screen reads `/api/v2/reading/continue` (one request, all
positions) while everything below it reads OPDS 2.0 (paged, cacheable,
standard).
]]

local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local ffiUtil = require("ffi/util")
local _ = require("gettext")
local T = ffiUtil.template

local Opds = require("stump_opds")
local Url = require("stump_url")

local Browser = Menu:extend{
    no_title = false,
    is_borderless = true,
    is_popout = false,
    title = _("Stump"),
    -- Injected by the plugin.
    api = nil,
    download_dir = nil,
    --- `function(path, book)` — called once the file is on disk (or was
    --- already there). The plugin owns opening it, because whether that is
    --- `openFile` or `switchDocument` depends on where the browser was opened
    --- from.
    on_download_complete = nil,
}

local PAGE_SIZE = 40

function Browser:init()
    self.paths = {}
    self.item_table = self:rootItems()
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function() self:showSearchDialog() end
    Menu.init(self)
end

-- ------------------------------------------------------------------- root

--- The five entry points.
---
--- `/opds/v2.0/books/browse` is deliberately absent. Its handler takes
--- `BrowseParams`, which `#[serde(flatten)]`s the pagination struct, and a
--- flattened serde struct cannot coerce a query string: `?page=1` is a `400`
--- ("invalid type: string \"1\", expected u64"), and so is the `next` link the
--- feed itself emits. Every other feed here takes `Query<OffsetPagination>`
--- directly and pages correctly. "Latest books", a library, a series, and
--- search already reach every book, so nothing is lost by not offering a feed
--- whose second page cannot be fetched.
function Browser:rootItems()
    local paged = { page_size = PAGE_SIZE }
    return {
        { text = _("Continue reading"), kind = "dashboard" },
        { text = _("Libraries"), kind = "opds",
          url = Url.opds(self.api.base, "/libraries") },
        { text = _("Series"), kind = "opds",
          url = Url.opds(self.api.base, "/series", paged) },
        { text = _("Latest books"), kind = "opds",
          url = Url.opds(self.api.base, "/books/latest", paged) },
        { text = _("Search…"), kind = "search" },
    }
end

local function fail(message, detail)
    UIManager:show(InfoMessage:new{
        text = detail and T("%1\n%2", message, tostring(detail)) or message,
        icon = "notice-warning",
    })
end

-- -------------------------------------------------------------- dashboard

--- Percentage text for a head, or nil.
---
--- `progression` is `0..=1` whole-publication progress; `page` is present only
--- for a page-addressed head. Both are shown when both exist because "43% ·
--- p. 120" answers two different questions.
function Browser.progressLabel(item)
    local parts = {}
    local progression = tonumber(item.progression)
    if progression then
        table.insert(parts, string.format("%d%%", math.floor(progression * 100 + 0.5)))
    end
    local page = tonumber(item.page)
    if page then
        local pages = tonumber(item.pages)
        if pages and pages > 0 then
            table.insert(parts, T(_("p. %1/%2"), page, pages))
        else
            table.insert(parts, T(_("p. %1"), page))
        end
    end
    local position_ms = tonumber(item.positionMs)
    if position_ms and not page then
        table.insert(parts, string.format("%d:%02d",
            math.floor(position_ms / 60000),
            math.floor(position_ms / 1000) % 60))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " · ")
end

function Browser:showDashboard(push_path)
    local items, err, code = self.api:continueReading(20)
    if not items then
        return fail(_("Could not load your reading list."), code or err)
    end
    if #items == 0 then
        return fail(_("Nothing in progress on this server yet."))
    end

    local rows = {}
    for _, item in ipairs(items) do
        local label = item.name or "(untitled)"
        if item.seriesName and item.seriesName ~= label then
            label = item.seriesName .. " — " .. label
        end
        local progress = Browser.progressLabel(item)
        table.insert(rows, {
            text = progress and (label .. "  (" .. progress .. ")") or label,
            kind = "book",
            book = {
                id = item.mediaId,
                title = item.name,
                series = item.seriesName,
                extension = item.extension,
                koreader_hash = item.koreaderHash,
            },
        })
    end

    if push_path then
        table.insert(self.paths,
            { kind = "dashboard", title = _("Continue reading") })
    end
    self:switchItemTable(_("Continue reading"), rows)
end

-- --------------------------------------------------------------- OPDS 2.0

--- Turns one OPDS 2.0 feed into menu rows.
---
--- Groups are flattened inline (the catalogue root is three groups), because a
--- device menu with one level per group would put every real entry two taps
--- away from where the server put it.
function Browser:rowsFromFeed(feed, feed_url)
    local view = Opds.feed(self.api.base, feed)
    local rows = {}

    for _, nav in ipairs(view.navigation) do
        table.insert(rows, { text = nav.title, kind = "opds", url = nav.url })
    end

    for _, pub in ipairs(view.publications) do
        table.insert(rows, self:bookRow(pub))
    end

    for _, group in ipairs(view.groups) do
        local has_entries = #group.navigation > 0 or #group.publications > 0
        if has_entries then
            table.insert(rows, { text = "— " .. group.title .. " —", kind = "noop" })
            for _, nav in ipairs(group.navigation) do
                table.insert(rows, { text = nav.title, kind = "opds", url = nav.url })
            end
            for _, pub in ipairs(group.publications) do
                table.insert(rows, self:bookRow(pub))
            end
            if group.url and #group.publications > 0 then
                table.insert(rows, {
                    text = T(_("More in %1…"), group.title),
                    kind = "opds",
                    url = group.url .. (group.url:find("?", 1, true) and "&" or "?")
                        .. "page_size=" .. PAGE_SIZE,
                })
            end
        end
    end

    if view.paging.next_url and #view.publications > 0 then
        local per_page = view.paging.per_page or PAGE_SIZE
        -- Stump emits `next` on every feed, so only offer it when this page
        -- was actually full.
        if #view.publications >= per_page then
            table.insert(rows, {
                text = _("Next page →"),
                kind = "opds",
                url = view.paging.next_url,
            })
        end
    end

    if #rows == 0 then
        table.insert(rows, { text = _("(empty)"), kind = "noop" })
    end

    return rows, view.title or feed_url
end

function Browser:bookRow(pub)
    local label = pub.title
    if pub.series and pub.series ~= pub.title then
        label = pub.series .. " — " .. label
    end
    if pub.track_count then
        label = label .. T(_("  (%1 audio tracks)"), pub.track_count)
    elseif pub.extension then
        label = label .. "  (" .. pub.extension .. ")"
    end
    return {
        text = label,
        kind = "book",
        book = {
            id = pub.id,
            title = pub.title,
            series = pub.series,
            extension = pub.extension,
            track_count = pub.track_count,
        },
    }
end

function Browser:openFeed(url, push_path)
    local feed, err, code = self.api:opdsGet(url)
    if not feed then
        return fail(_("Could not load the catalogue."), code or err)
    end
    local rows, title = self:rowsFromFeed(feed, url)
    if push_path then
        table.insert(self.paths, { kind = "opds", url = url, title = title })
    end
    self:switchItemTable(title, rows)
end

-- --------------------------------------------------------------- searching

function Browser:showSearchDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Stump"),
        input_hint = _("title, author or series"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputText()
                UIManager:close(dialog)
                if not query or query == "" then return end
                NetworkMgr:runWhenConnected(function()
                    self:openFeed(Url.opds(self.api.base, "/search",
                        { query = query, page_size = PAGE_SIZE }), true)
                end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- --------------------------------------------------------------- downloads

function Browser:localPathFor(book)
    local dir = self.download_dir
    if not dir or dir == "" then return nil, "no_download_dir" end
    if not lfs.attributes(dir, "mode") then
        local ok = util.makePath(dir)
        if not ok then return nil, "cannot_create_download_dir" end
    end
    local name = util.getSafeFilename(Opds.filename(book), dir)
    return (dir ~= "/" and dir or "") .. "/" .. name
end

function Browser:downloadAndOpen(book)
    if not book.id then
        return fail(_("This entry has no Stump book id."))
    end
    if book.track_count then
        return fail(_("Multi-file audiobooks cannot be downloaded as one file."))
    end
    if not book.extension then
        -- Stump knows the type; we only refuse to guess a filename extension.
        book = { id = book.id, title = book.title, series = book.series,
                 extension = "epub", koreader_hash = book.koreader_hash }
    end

    local path, err = self:localPathFor(book)
    if not path then return fail(_("No usable download folder."), err) end

    local function start()
        UIManager:show(InfoMessage:new{ text = _("Downloading…"), timeout = 1 })
        UIManager:scheduleIn(0.1, function()
            local saved, download_err, code =
                self.api:downloadBook(book.id, path)
            if not saved then
                return fail(_("Download failed."), code or download_err)
            end
            self.on_download_complete(saved, book)
        end)
    end

    if lfs.attributes(path) then
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 already exists."), BD.filepath(path)),
            ok_text = _("Overwrite"),
            ok_callback = start,
            other_buttons = {{{
                text = _("Open existing"),
                callback = function() self.on_download_complete(path, book) end,
            }}},
        })
    else
        start()
    end
end

-- ----------------------------------------------------------------- events

function Browser:onMenuSelect(item)
    if item.kind == "noop" then return true end

    if item.kind == "book" then
        NetworkMgr:runWhenConnected(function()
            self:downloadAndOpen(item.book)
        end)
        return true
    end

    if item.kind == "search" then
        self:showSearchDialog()
        return true
    end

    if item.kind == "dashboard" then
        NetworkMgr:runWhenConnected(function() self:showDashboard(true) end)
        return true
    end

    if item.kind == "opds" and item.url then
        NetworkMgr:runWhenConnected(function() self:openFeed(item.url, true) end)
        return true
    end

    logger.warn("Stump: unhandled menu item", item.kind)
    return true
end

--- Back: drop the level being left and re-render its parent.
---
--- `push_path = false` on the re-render, because the parent's entry is
--- already on the stack — the same contract KOReader's own OPDS browser uses
--- for its `paths_updated` flag.
function Browser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if not path then
        self:switchItemTable(_("Stump"), self:rootItems())
        return true
    end
    NetworkMgr:runWhenConnected(function()
        if path.kind == "dashboard" then
            self:showDashboard(false)
        else
            self:openFeed(path.url, false)
        end
    end)
    return true
end

return Browser
