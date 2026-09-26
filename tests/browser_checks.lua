package.path = "coppice.koplugin/?.lua;" .. package.path

local function widgetClass()
    local class = {}
    class.__index = class
    function class:extend(defaults)
        local child = setmetatable({}, { __index = self })
        child.__index = child
        for key, value in pairs(defaults or {}) do child[key] = value end
        function child:new(args)
            args = args or {}
            setmetatable(args, { __index = child })
            -- Like Widget:new: base `_init` first, then the widget's `init`.
            if args._init then args:_init() end
            if args.init then args:init() end
            return args
        end
        return child
    end
    function class:new(args)
        args = args or {}
        setmetatable(args, { __index = self })
        if args._init then args:_init() end
        return args
    end
    local function childSize(child)
        if type(child) ~= "table" then return 0, 0 end
        if child.getSize then
            local size = child:getSize()
            return size.w or 0, size.h or 0
        end
        return child.width or child.max_width or 0, child.height or 0
    end
    function class:getSize()
        if self.dimen then return self.dimen end
        if self.width and self.height then return { w = self.width, h = self.height } end
        local width, height = 0, 0
        for _, child in ipairs(self) do
            local child_width, child_height = childSize(child)
            width = width + child_width
            height = height + child_height
        end
        if self.height then height = self.height end
        if self.width then width = self.width end
        return { w = width, h = height }
    end
    function class:free() end
    return class
end

-- KOReader's global reader settings, in memory.
do
    local store = {}
    G_reader_settings = {
        readSetting = function(_self, key, default) if store[key] == nil then return default end return store[key] end,
        saveSetting = function(_self, key, value) store[key] = value end,
        nilOrTrue = function(_self, key) return store[key] == nil or store[key] == true end,
        isTrue = function(_self, key) return store[key] == true end,
    }
end

local Widget = widgetClass()
local function module(name, value)
    package.preload[name] = function() return value end
end
local function classModule(name)
    module(name, widgetClass())
end

for _, name in ipairs({
    "ui/widget/button", "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer", "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan", "ui/widget/imagewidget",
    "ui/widget/container/inputcontainer", "ui/widget/inputdialog",
    "ui/widget/progresswidget", "ui/widget/textboxwidget",
    "ui/widget/textwidget", "ui/widget/verticalgroup", "ui/widget/verticalspan",
    "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/titlebar",
    "ui/widget/iconbutton", "ui/widget/container/scrollablecontainer",
    "ui/widget/container/leftcontainer", "ui/widget/container/rightcontainer",
    "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/iconwidget",
    "ui/widget/container/bottomcontainer",
}) do classModule(name) end
-- Match KOReader: VerticalSpan keeps its height in `width`.
do
    local span = require("ui/widget/verticalspan")
    function span:getSize() return { w = 0, h = self.width or 0 } end
end
require("ui/widget/container/scrollablecontainer").scroll_bar_width = 6
-- InputContainer as KOReader master (1c8724e9) builds it: `_init` owns the
-- instance key_events table and binds the physical Home key in it.
do
    local InputContainer = require("ui/widget/container/inputcontainer")
    function InputContainer:_init()
        self.key_events = self.key_events or {}
        if require("device"):hasKeys() then self.key_events.Home = { { "Home" } } end
        self.ges_events = self.ges_events or {}
    end
    -- KOReader's key dispatch, reduced to one unmodified key name.
    function InputContainer:onKeyPress(key)
        for name, seq in pairs(self.key_events) do
            for _, oneseq in ipairs(seq) do
                local wanted = oneseq[1]
                local hit = wanted == key
                if type(wanted) == "table" then
                    for _, variant in ipairs(wanted) do hit = hit or variant == key end
                end
                if hit and self["on" .. name] then return self["on" .. name](self) end
            end
        end
    end
end
module("ui/size", { line = { thick = 2, thin = 1 }, border = { thick = 2 }, radius = { button = 7 } })

local screen_width, screen_height = 671, 1568
local screen = {
    getWidth = function() return screen_width end,
    getHeight = function() return screen_height end,
    scaleBySize = function(_, value) return value end,
}
module("device", { screen = screen, hasKeys = function() return true end,
    input = { group = { Back = { "Back" } } } })
module("ui/event", { new = function(_, name) return { handler = "on" .. name } end })
module("datastorage", { getDataDir = function() return "/tmp" end,
    getSettingsDir = function() return "/tmp" end })
module("ui/network/manager", { runWhenConnected = function(_, callback) callback() end,
    is_connected = true, is_wifi_on = true })
local ui_manager = {
    setDirty = function() end,
    show = function(self, widget) self.shown = widget end,
    close = function(self, widget) self.closed = widget end,
    nextTick = function(_, callback) callback() end,
    sendEvent = function(self, event) self.sent = event end,
}
module("ui/uimanager", ui_manager)
module("ui/font", { getFace = function(_, _, size) return size end })
local function geom(value)
    value.copy = function(self) return geom({ x = self.x, y = self.y, w = self.w, h = self.h }) end
    return value
end
module("ui/geometry", { new = function(_, value) return geom(value) end })
module("ui/gesturerange", { new = function(_, value) return value end })
module("ffi/blitbuffer", { COLOR_WHITE = "white", COLOR_BLACK = "black",
    COLOR_GRAY = "gray", COLOR_LIGHT_GRAY = "lightgray", COLOR_DARK_GRAY = "darkgray",
    HIGHLIGHT_COLORS = { yellow = "#FFFF33", green = "#00AA66", blue = "#0066FF" },
    ColorRGB32 = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end })
local local_files = {}
module("libs/libkoreader-lfs", {
    attributes = function(path, field)
        if not local_files[path] then return nil end
        if field == "mode" then return "file" end
        return { mode = "file", size = 1, modification = 1 }
    end,
    dir = function()
        local names = { ".", ".." }
        local index = 0
        return function()
            index = index + 1
            return names[index]
        end
    end,
})
module("util", { makePath = function() return true end })
module("gettext", setmetatable({}, { __call = function(_, value) return value end,
    __index = { pgettext = function(_, _, value) return value end } }))
module("ffi/util", { template = function(text, ...)
    local args = { ... }
    return (text:gsub("%%(%d+)", function(index)
        return tostring(args[tonumber(index)] or "")
    end))
end })
module("coppice_errors", { describe = function(_, error) return tostring(error) end })
local InputDialog = widgetClass():extend()
function InputDialog:new(args)
    args.input_text = ""
    return setmetatable(args, { __index = self })
end
function InputDialog:getInputText() return self.input_text end
function InputDialog:onShowKeyboard() self.keyboard_shown = true end
function InputDialog:pressEnter()
    for _, row in ipairs(self.buttons or {}) do
        for _, button in ipairs(row) do
            if button.is_enter_default then
                button.callback()
                return true
            end
        end
    end
    return false
end
module("ui/widget/inputdialog", InputDialog)

local Browser = require("coppice_browser")
local asset_requests = 0
local media = {}
for index = 1, 305 do
    media[index] = {
        id = string.format("media-%03d", index),
        name = "book-" .. index,
        extension = "epub",
        metadata = { title = "Fixture book " .. index, writers = { "Test Author" } },
        readProgress = {},
        tags = {},
    }
end
local search_calls, search_request = 0, nil
local api = {
    base = "http://fixture.invalid",
    continueReading = function() return {} end,
    graphql = function(_, query, variables)
        if query:find("searchBooks", 1, true) then
            search_calls = search_calls + 1
            search_request = { query = query, variables = variables }
            return { searchBooks = {
                {
                    mediaId = "26c63f7e-2186-4b40-8578-7c95c6edaf83",
                    title = "Ender's Game",
                    authors = { "Orson Scott Card" },
                },
                {
                    mediaId = "e80ee832-3710-4415-af6e-0be29a9512cf",
                    title = "rust_book",
                    authors = {},
                },
            } }
        end
        if query:find("librariesStats", 1, true) then
            return { librariesStats = { bookCount = 305, inProgressBooks = 0 } }
        end
        if query:find("recentlyAddedMedia", 1, true) then
            return { recentlyAddedMedia = { nodes = {}, pageInfo = {
                totalItems = 0, totalPages = 1, currentPage = 1, pageSize = 12,
            } } }
        end
        if query:find("media(", 1, true) then
            return { media = { nodes = media, pageInfo = {
                totalItems = 305, totalPages = 26, currentPage = 22, pageSize = 12,
            } } }
        end
        error("unexpected fixture query")
    end,
    downloadAsset = function()
        asset_requests = asset_requests + 1
        return nil, "fixture has no covers"
    end,
}

local browser = Browser:new{ api = api, cache_dir = "/tmp/coppice-harness-covers" }
asset_requests = 0
browser:loadMediaList({ kind = "all_books", title = "All Books", page = 22 })
assert(asset_requests > 0 and asset_requests <= browser.layout.page_size,
    "All books must create/load only one page of covers (" .. browser.layout.page_size
        .. "), got " .. asset_requests)
print("browser_checks: All books created " .. asset_requests .. " covers (one page) from 305 fixture books")
local search_browser = Browser:new{
    api = api,
    cache_dir = "/tmp/coppice-harness-search-covers",
}
local standard_grid, visible_tiles, rendered_controls
local render_book_list = search_browser.renderBookList
search_browser.renderBookList = function(self, state)
    standard_grid = state
    return render_book_list(self, state)
end
local render_paged_screen = search_browser.renderPagedScreen
search_browser.renderPagedScreen = function(self, header, body, footer, width)
    rendered_controls = { footer = footer }
    return render_paged_screen(self, header, body, footer, width)
end
local cover_tile = search_browser.coverTile
search_browser.coverTile = function(self, ...)
    visible_tiles = (visible_tiles or 0) + 1
    return cover_tile(self, ...)
end
local requests_before_search = asset_requests
search_browser:search()
local dialog = ui_manager.shown
assert(dialog and dialog.keyboard_shown, "search opens the keyboard dialog")
dialog.input_text = "Ender's Game"
assert(dialog:pressEnter(), "KOReader Enter selects the default Search button")
dialog:pressEnter()
assert(ui_manager.closed == dialog, "submitting search closes the dialog")
assert(search_calls == 1, "one dialog submit sends one GraphQL search")
assert(search_request.query:find(
    "searchBooks(query: $query, limit: $limit)", 1, true),
    "dialog submit calls the server searchBooks query")
assert(search_request.variables.query == "Ender's Game"
        and search_request.variables.limit == 50,
    "search sends the entered query and result limit")
assert(standard_grid == search_browser.screen_state
        and standard_grid.kind == "search" and standard_grid.total == 2,
    "search response is rendered through the standard paginated book grid")
assert(standard_grid.items[1].id == "26c63f7e-2186-4b40-8578-7c95c6edaf83"
        and standard_grid.items[1].authors == "Orson Scott Card",
    "searchBooks mediaId/title/authors are mapped into book tiles")
assert(visible_tiles == 2 and asset_requests - requests_before_search == 2,
    "the standard grid creates and loads only its two visible search covers")
-- Bottom bar: [List] « ‹ label › » [headphones], gap spans between.
local footer = rendered_controls.footer
assert(footer[1][1].height >= 48, "List/Covers toggle sits in the bottom bar at touch size")
for _, index in ipairs({ 3, 5, 9, 11 }) do
    assert(footer[index].height >= 48, "catalog pager buttons meet the scaled touch target")
end
print("browser_checks: search dialog submit requested and rendered live-shape results in the standard grid")

local continue_browser = Browser:new{
    api = api,
    cache_dir = "/tmp/coppice-harness-continue-covers",
}
local opened_path, detail_item
continue_browser.on_open_file = function(path) opened_path = path end
continue_browser.openItem = function(_, item) detail_item = item end
local downloaded_path = "/tmp/coppice-harness-book.epub"
local_files[downloaded_path] = true
local downloaded = {
    id = "downloaded-book",
    title = "Downloaded",
    local_path = downloaded_path,
    progression = 0.4,
    kind = "book",
    cover_kind = "media",
}
local width = screen_width - 2 * continue_browser.layout.margin
local row = continue_browser:continueRow({ continues = { downloaded } }, width)
local downloaded_tile = row[3][1]
downloaded_tile:onTapSelect()
assert(opened_path == downloaded_path and detail_item == nil,
    "tap on a valid downloaded continue cover opens the reader directly")
downloaded_tile:onHoldSelect()
assert(detail_item == downloaded,
    "long-press on a continue cover opens book details")
local missing = {
    id = "missing-book",
    title = "Missing",
    local_path = "/tmp/coppice-harness-missing.epub",
    progression = 0.2,
    kind = "book",
    cover_kind = "media",
}
opened_path, detail_item = nil, nil
continue_browser:openContinue(missing)
assert(opened_path == nil and detail_item == missing,
    "continue book without a valid local file opens details")
print("browser_checks: continue-cover tap and long-press decisions passed")

local function assertTouchTargets(widget, label)
    if type(widget) ~= "table" then return 0 end
    local count = 0
    if type(widget.callback) == "function" then
        assert(widget.width >= 48 and widget.height >= 48,
            label .. " has a touch target below 48 px")
        count = 1
    end
    for _, child in ipairs(widget) do
        count = count + assertTouchTargets(child, label)
    end
    return count
end

for _, size in ipairs({ { 671, 1568 }, { 1072, 1448 } }) do
    screen_width, screen_height = size[1], size[2]
    local sized = Browser:new{
        api = api,
        cache_dir = "/tmp/coppice-harness-layout-covers",
    }
    sized.on_sync_annotations = function() end
    sized.on_remote_notes = function() end
    local layout = sized.layout
    assert(layout.columns >= 2 and layout.columns <= 4
            and layout.page_size == layout.columns * layout.rows,
        "grid uses 2-4 columns and a columns x rows page")
    assert(layout.tile_width * layout.columns + layout.gap * (layout.columns - 1)
            + 2 * layout.margin <= screen_width,
        "cover columns and margins do not overlap")
    assert(layout.tile_width >= 48 and layout.cover_height >= 48,
        "cover tiles meet the scaled touch target")
    local page_width = screen_width - 2 * layout.margin
    local pager = sized:pagingControls({ page = 1, page_count = 2 }, page_width,
        { list_toggle = true, audio_toggle = true })
    for _, index in ipairs({ 3, 5, 9, 11 }) do
        assert(pager[index].width >= 48 and pager[index].height >= 48,
            "page navigation meets the scaled touch target")
    end
    local home_pager = sized:homePager(1, 2, page_width, function() end)
    assert(home_pager[1].width >= 48 and home_pager[1].height >= 48
            and home_pager[5].width >= 48 and home_pager[5].height >= 48,
        "Home pagination meets the scaled touch target")
    assert(assertTouchTargets(sized:browseCategories(page_width), "Browse grid") == 9,
        "all nine Browse actions (3 x 3) fit and meet touch targets")
    assert(assertTouchTargets(
        sized:recentAnnotationsRow({ annotations = {} }, page_width),
        "See all annotations") == 1,
        "See all notes control meets the scaled touch target")
    print(string.format("browser_checks: %dx%d grid has no overlap and touch targets >=48 px",
        screen_width, screen_height))
end

-- Physical keys. KOReader master binds Home on every InputContainer in
-- `_init`; the browser must merge its own bindings into that table, close on
-- Home through onClose(), and still close on v2026.07.1 where the base class
-- has no onHome().
do
    local InputContainer = require("ui/widget/container/inputcontainer")
    local closed = 0
    local keyed = Browser:new{
        api = api,
        cache_dir = "/tmp/coppice-harness-keys-covers",
        close_callback = function() closed = closed + 1 end,
    }
    assert(keyed.key_events.Home and keyed.key_events.Back,
        "Back is merged next to the Home binding KOReader made")
    keyed:openScreen({ kind = "all_books", title = "All Books" })
    assert(keyed:onKeyPress("Back") == true and #keyed.history == 0 and closed == 0,
        "Back key steps back through the browser's history")
    -- v2026.07.1: no InputContainer:onHome, the browser closes itself and
    -- hands Home to the reader or file manager underneath.
    ui_manager.sent = nil
    assert(keyed:onKeyPress("Home") == true and closed == 1,
        "Home key closes the browser on KOReader v2026.07.1")
    assert(ui_manager.sent and ui_manager.sent.handler == "onHome",
        "Home is re-sent so the widget underneath acts on it too")
    -- master: the inherited handler closes window-level widgets via onClose().
    local upstream_calls = 0
    function InputContainer:onHome()
        upstream_calls = upstream_calls + 1
        return self:onClose()
    end
    ui_manager.sent = nil
    assert(keyed:onKeyPress("Home") == true and upstream_calls == 1 and closed == 2
            and ui_manager.sent == nil,
        "on KOReader master the upstream Home daisy-chain closes the browser through onClose")
    InputContainer.onHome = nil
    assert(keyed:onClose() == true and closed == 3,
        "KOReader's Close broadcast (exit, USB storage) closes the browser")
    -- Sub-widgets keep KOReader's own instance bindings and add none.
    local tile = keyed:coverTile(media[1], 200, 260, function() end)
    assert(tile.key_events ~= keyed.key_events and tile.key_events.Home
            and tile.key_events.Back == nil,
        "cover tiles keep the Home binding KOReader made and no browser bindings")
    print("browser_checks: Home/Back/Close key handling passed for v2026.07.1 and master")
end

-- Highlight chips are tinted with the reader's own colours: a custom code the
-- user set for a KOReader colour name wins over the built-in, unknown names
-- keep their fallback.
do
    local function chipOf(item)
        local card = Browser:new{ api = api, cache_dir = "/tmp/coppice-harness-chip-covers" }
            :annotationCard(item, 500)
        return card[1][1][1][1][1][1]
    end
    local builtin = chipOf({ id = "1", kind = "highlight", color = "yellow", title = "Book" })
    assert(builtin.color.r == 255 and builtin.color.g == 255 and builtin.color.b == 0x33,
        "built-in KOReader colours tint the chip border with their hex code")
    assert(builtin.background.r == 255 and builtin.background.b == math.floor(0x33 * 0.45 + 255 * 0.55),
        "the chip fill is the colour mixed towards white")
    G_reader_settings:saveSetting("highlight_custom_colors", {
        yellow = { name = "Sand", code = "#C0A060" },
        green = { name = "Moss" }, -- renamed only: keeps the built-in code
        blue = { code = "not a colour" },
    })
    local custom = chipOf({ id = "2", kind = "highlight", color = "Yellow", title = "Book" })
    assert(custom.color.r == 0xC0 and custom.color.g == 0xA0 and custom.color.b == 0x60,
        "a custom colour code from the reader settings tints the chip")
    local renamed = chipOf({ id = "3", kind = "highlight", color = "green", title = "Book" })
    assert(renamed.color.r == 0x00 and renamed.color.g == 0xAA and renamed.color.b == 0x66,
        "a renamed colour without a custom code keeps KOReader's built-in code")
    local invalid = chipOf({ id = "4", kind = "highlight", color = "blue", title = "Book" })
    assert(invalid.color.r == 0x00 and invalid.color.g == 0x66 and invalid.color.b == 0xFF,
        "a malformed custom code is ignored in favour of the built-in")
    local pink = chipOf({ id = "5", kind = "highlight", color = "pink", title = "Book" })
    assert(pink.color.r == 0xFF and pink.color.g == 0x66 and pink.color.b == 0xAA,
        "Liseur's pink keeps its fallback colour")
    assert(chipOf({ id = "6", kind = "note", title = "Book" }).color == "black",
        "uncoloured notes keep the plain chip")
    G_reader_settings:saveSetting("highlight_custom_colors", nil)
    print("browser_checks: highlight chips follow the reader's custom colours")
end
