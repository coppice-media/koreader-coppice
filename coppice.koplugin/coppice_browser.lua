--[[--
Coppice's cover-first KOReader library. This UI uses KOReader's standard
ImageWidget, TextBoxWidget, Button, and container widgets; network and cache
work is performed only for the screen and covers currently visible.
]]

local Button = require("ui/widget/button")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local FrameContainer = require("ui/widget/container/framecontainer")
local IconButton = require("ui/widget/iconbutton")
local IconWidget = require("ui/widget/iconwidget")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local NetworkMgr = require("ui/network/manager")
local ProgressWidget = require("ui/widget/progresswidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Blitbuffer = require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Catalog = require("coppice_catalog")
local Errors = require("coppice_errors")

local Screen = Device.screen
local COVER_CACHE_BYTES = 24 * 1024 * 1024
local MEDIA_FIELDS = [[
    id name resolvedName extension pages status createdAt seriesId audio { durationMs }
    metadata { title writers year publisher pageCount summary series }
    tags { name }
    series { id name resolvedName }
    readProgress { page positionMs percentageCompleted }
]]
local PAGE_INFO_FIELDS = [[
    pageInfo { ... on OffsetPaginationInfo { totalItems totalPages currentPage pageSize } }
]]

local Browser = InputContainer:extend{
    -- Not modal: KOReader stacks non-modal widgets (search box, keyboard,
    -- messages) below modal ones, which hid them behind this full screen.
    covers_fullscreen = true,
    api = nil,
    download_dir = nil,
    on_download_complete = nil,
    on_open_file = nil,
    on_open_annotation = nil,
    on_recent_annotations = nil,
    on_pending_count = nil,
    close_callback = nil,
    on_sync_annotations = nil,
    on_remote_notes = nil,
    screen_state = nil,
    history = nil,
    loading_generation = 0,
    list_mode = false,
    cache_dir = nil,
}

local function content(value)
    if value == nil or value == "" then return "" end
    return tostring(value)
end

local function textWidget(text, width, height, size, align, bold)
    return TextBoxWidget:new{
        text = content(text),
        face = Font:getFace("cfont", size or 18),
        width = math.max(1, width),
        height = height,
        height_adjust = true,
        height_overflow_show_ellipsis = height ~= nil,
        alignment = align or "left",
        bold = bold,
        line_height = 0.15,
    }
end

local function singleLine(text, width, size, bold)
    return TextWidget:new{
        text = content(text),
        face = Font:getFace("cfont", size or 18),
        max_width = width,
        bold = bold,
    }
end

local function makeButton(label, callback, width, height, opts)
    opts = opts or {}
    return Button:new{
        text = label,
        callback = callback,
        width = width,
        height = height,
        padding = opts.padding or 5,
        margin = opts.margin or 0,
        bordersize = opts.bordersize or 1,
        radius = opts.radius,
        text_font_face = opts.font or "cfont",
        text_font_size = opts.size or 18,
        text_font_bold = opts.bold ~= false,
        align = opts.align or "center",
        -- No `background`: KOReader's Button draws its border in the
        -- background colour when one is set, which hid every border.
        avoid_text_truncation = true,
    }
end

local function spacedRow(items, gap)
    local row = { align = "top" }
    for index, item in ipairs(items) do
        if index > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = item
    end
    return HorizontalGroup:new(row)
end


function Browser:init()
    self.history = {}
    self.layout = Catalog.layout(Screen:getWidth(), Screen:getHeight(), Screen:scaleBySize(1000) / 1000)
    self.cache_dir = DataStorage:getDataDir() .. "/cache/coppice-covers"
    self.key_events = {
        Back = { { "Back" } },
        Escape = { { "Esc" } },
    }
    self.screen_state = { kind = "home", title = _("Coppice") }
    self.screen_state.data = self:cachedHomeData()
    self:renderHome(self.screen_state.data)
    self:loadHomeWhenConnected()
end

function Browser:onBack()
    self:back()
    return true
end

function Browser:onEscape()
    self:back()
    return true
end

function Browser:onReturn()
    self:back()
    return true
end

function Browser:close()
    if self.close_callback then
        self.close_callback()
    else
        UIManager:close(self)
    end
end

function Browser:back()
    if #self.history > 0 then
        self.screen_state = table.remove(self.history)
        self:loadCurrentScreen()
    else
        self:close()
    end
end

function Browser:home()
    self.history = {}
    self.screen_state = { kind = "home", title = _("Coppice") }
    self:loadCurrentScreen()
end

function Browser:openScreen(state)
    self.history[#self.history + 1] = self.screen_state
    self.screen_state = state
    self.list_mode = false
    self:loadCurrentScreen()
end

function Browser:runConnected(callback)
    local generation = self.loading_generation + 1
    self.loading_generation = generation
    NetworkMgr:runWhenConnected(function()
        if generation == self.loading_generation then callback() end
    end)
end

function Browser:loadHomeWhenConnected()
    self:runConnected(function() self:loadHome() end)
end

function Browser:loadCurrentScreen()
    local state = self.screen_state or { kind = "home", title = _("Coppice") }
    if state.kind ~= "home" then self:renderLoading(state.title or _("Coppice")) end
    self:runConnected(function()
        if self.screen_state == state then self:loadScreen(state) end
    end)
end

function Browser:graphql(query, variables)
    local data, err, code = self.api:graphql(query, variables)
    -- Any answer (even an error status) means the server is reachable; a
    -- transport failure has no status code.
    self.server_reachable = data ~= nil or code ~= nil
    if not data then return nil, err, code end
    return data, nil, code
end

function Browser:cachedHomeData()
    local device_items = self:onDeviceItems()
    local titles = {}
    for _unused, item in ipairs(device_items) do
        if item.id then titles[tostring(item.id)] = item.title end
    end
    return {
        continues = {},
        continue_page = self.home_continue_page or 1,
        recent = {},
        recent_history = self:recentHistory(titles),
        annotations = self:recentAnnotations(titles, true),
        reading_stats = self:readLocalStatistics(),
        library_count = nil,
        progress_count = nil,
        on_device_count = #device_items,
        device_items = device_items,
        server_reachable = false,
        recent_page = self.home_recent_page or 1,
        recent_total = 0,
        recent_page_count = 1,
    }
end

function Browser:loadHome()
    local continues = self.api:continueReading(50)
    local home = self:cachedHomeData()
    local page = math.max(1, tonumber(self.home_recent_page) or 1)
    local recent_data = self:graphql([[query($pagination: Pagination!) {
        recentlyAddedMedia(pagination: $pagination) { nodes { ]] .. MEDIA_FIELDS .. [[ }
        ]] .. PAGE_INFO_FIELDS .. [[ }
    }]], { pagination = { offset = {
        page = page, pageSize = self.layout.columns, zeroBased = false,
    } } })
    local stats_data = self:graphql([[query {
        librariesStats { bookCount inProgressBooks }
    }]])
    local recent = {}
    local recent_response = recent_data and recent_data.recentlyAddedMedia
    for _unused, item in ipairs(recent_response and recent_response.nodes or {}) do
        local mapped = Catalog.media(item)
        if mapped then recent[#recent + 1] = mapped end
    end
    local latest_stats = stats_data and stats_data.librariesStats or {}
    home.library_count = tonumber(latest_stats.bookCount)
    home.progress_count = tonumber(latest_stats.inProgressBooks)
    home.recent = recent
    home.recent_total, home.recent_page_count = self:pageInfo(recent_response)
    home.recent_page = page
    home.server_reachable = continues ~= nil or recent_data ~= nil or stats_data ~= nil

    local titles = {}
    local device_by_id = {}
    for _unused, item in ipairs(home.device_items) do
        device_by_id[tostring(item.id)] = item
    end
    for _unused, item in ipairs(home.device_items) do
        titles[tostring(item.id)] = item.title
    end
    for _unused, item in ipairs(recent) do
        titles[tostring(item.id)] = item.title
    end
    for _unused, item in ipairs(continues or {}) do
        local mapped = Catalog.continueItem(item)
        if mapped then
            mapped.kind = "book"
            local local_copy = device_by_id[tostring(mapped.id)]
            if local_copy then mapped.local_path = local_copy.local_path end
            titles[tostring(mapped.id)] = mapped.title
            home.continues[#home.continues + 1] = mapped
        end
    end
    home.on_device_count = #home.device_items
    home.recent_history = self:recentHistory(titles)
    home.annotations = self:recentAnnotations(titles, false)
    home.reading_stats = self:readLocalStatistics()
    self.server_reachable = home.server_reachable
    self.screen_state.data = home
    self:renderHome(home)
end

function Browser:loadScreen(state)
    local kind = state.kind
    if kind == "home" then return self:loadHome() end
    if kind == "all_annotations" then return self:loadAllAnnotations(state) end
    if kind == "in_progress" then return self:loadContinueList(state) end
    if kind == "on_device" then
        state.items = self:onDeviceItems()
        state.total = #state.items
        state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
        state.page = state.page or 1
        state.local_paged = true
        state.sort_label = _("Title (A–Z)")
        return self:renderBookList(state)
    end
    if kind == "all_books" or kind == "recent_books" then
        return self:loadMediaList(state)
    end
    if kind == "libraries" then return self:loadLibraries(state) end
    if kind == "series" then return self:loadSeriesList(state) end
    if kind == "authors" then return self:loadAuthors(state) end
    if kind == "reading_lists" then return self:loadReadingLists(state) end
    if kind == "smart_lists" then return self:loadSmartLists(state) end
    if kind == "library_series" then return self:loadLibrarySeries(state) end
    if kind == "series_books" then return self:loadSeriesBooks(state) end
    if kind == "author_books" then return self:loadAuthorBooks(state) end
    if kind == "smart_list_books" then return self:loadSmartListBooks(state) end
    if kind == "reading_list_detail" then return self:renderReadingListDetail(state) end
    if kind == "search" then return self:loadSearchResults(state) end
    if kind == "detail" then return self:loadBookDetail(state) end
    return self:renderMessage(state.title, _( "This Coppice view is unavailable." ))
end

function Browser:pagination(page, size)
    return { offset = { page = page, pageSize = size, zeroBased = false } }
end

function Browser:pageInfo(response)
    local info = response and response.pageInfo
    if type(info) ~= "table" then return 0, 1 end
    return tonumber(info.totalItems) or 0, tonumber(info.totalPages) or 1
end

function Browser:loadContinueList(state)
    local data, err, code = self:graphql([[query($pagination: Pagination!) {
        keepReading(pagination: $pagination) { nodes { ]] .. MEDIA_FIELDS .. [[ }
        ]] .. PAGE_INFO_FIELDS .. [[ }
    }]], { pagination = self:pagination(state.page or 1, self.layout.page_size) })
    local response = data and data.keepReading
    if not response then return self:renderError(state.title, err, code) end
    local nodes = response.nodes or {}
    state.local_paged = #nodes > self.layout.page_size
    state.items = {}
    for _unused, item in ipairs(nodes) do
        local mapped = Catalog.media(item)
        if mapped then mapped.kind = "book"; state.items[#state.items + 1] = mapped end
    end
    state.total, state.page_count = self:pageInfo(response)
    state.page = state.page or 1
    state.sort_label = _("Recently updated")
    self:renderBookList(state)
end

function Browser:loadMediaList(state)
    local page_size = self.layout.page_size
    local pagination = self:pagination(state.page or 1, page_size)
    local field = state.kind == "recent_books" and "recentlyAddedMedia" or "media"
    local query, variables
    if field == "media" and not self:showAudio() then
        -- Filtered on the server so page counts stay exact.
        query = [[query($pagination: Pagination!, $filter: MediaFilterInput!) {
            media(pagination: $pagination, filter: $filter) { nodes { ]] .. MEDIA_FIELDS .. [[ }
            ]] .. PAGE_INFO_FIELDS .. [[ }
        }]]
        variables = { pagination = pagination,
            filter = { extension = { noneOf = Catalog.AUDIO_EXTENSION_LIST } } }
    else
        query = [[query($pagination: Pagination!) {
            ]] .. field .. [[(pagination: $pagination) { nodes { ]] .. MEDIA_FIELDS .. [[ }
            ]] .. PAGE_INFO_FIELDS .. [[ }
        }]]
        variables = { pagination = pagination }
    end
    local data, err, code = self:graphql(query, variables)
    local response = data and data[field]
    if not response then return self:renderError(state.title, err, code) end
    local nodes = response.nodes or {}
    state.local_paged = #nodes > page_size
    state.items = {}
    for _unused, item in ipairs(nodes) do
        local mapped = Catalog.media(item)
        if mapped then state.items[#state.items + 1] = mapped end
    end
    state.total, state.page_count = self:pageInfo(response)
    state.page = state.page or 1
    state.sort_label = state.kind == "recent_books" and _("Recently added") or _("Title (A–Z)")
    self:renderBookList(state)
end

function Browser:loadLibraries(state)
    local data, err, code = self:graphql([[query($pagination: Pagination!) {
        libraries(pagination: $pagination) { nodes { id name description }
        ]] .. PAGE_INFO_FIELDS .. [[ }
    }]], { pagination = self:pagination(state.page or 1, self.layout.page_size) })
    local response = data and data.libraries
    if not response then return self:renderError(state.title, err, code) end
    state.items = {}
    for _unused, item in ipairs(response.nodes or {}) do
        state.items[#state.items + 1] = {
            id = item.id, title = item.name, summary = item.description,
            kind = "library", cover_kind = "placeholder",
        }
    end
    state.total, state.page_count = self:pageInfo(response)
    state.page = state.page or 1
    self:renderEntityList(state)
end

function Browser:loadSeriesList(state)
    local data, err, code = self:graphql([[query($pagination: Pagination!) {
        series(pagination: $pagination) { nodes { id name resolvedName resolvedDescription
            createdAt mediaCount percentageCompleted }
        ]] .. PAGE_INFO_FIELDS .. [[ }
    }]], { pagination = self:pagination(state.page or 1, self.layout.page_size) })
    local response = data and data.series
    if not response then return self:renderError(state.title, err, code) end
    state.items = {}
    for _unused, item in ipairs(response.nodes or {}) do
        local mapped = Catalog.series(item)
        if mapped then mapped.kind = "series"; state.items[#state.items + 1] = mapped end
    end
    state.total, state.page_count = self:pageInfo(response)
    state.page = state.page or 1
    state.sort_label = _("Title (A–Z)")
    self:renderEntityList(state)
end

function Browser:loadAuthors(state)
    local data, err, code = self:graphql([[query($pagination: Pagination!) {
        authors(pagination: $pagination) { nodes { name }
        ]] .. PAGE_INFO_FIELDS .. [[ }
    }]], { pagination = self:pagination(state.page or 1, self.layout.page_size) })
    local response = data and data.authors
    if not response then return self:renderError(state.title, err, code) end
    state.items = {}
    for _unused, item in ipairs(response.nodes or {}) do
        local mapped = Catalog.author(item)
        if mapped then state.items[#state.items + 1] = mapped end
    end
    state.total, state.page_count = self:pageInfo(response)
    state.page = state.page or 1
    state.sort_label = _("Name (A–Z)")
    self:renderEntityList(state)
end

function Browser:loadReadingLists(state)
    local data, err, code = self:graphql([[query($pagination: Pagination!) {
        readingLists(pagination: $pagination) { nodes { id name description visibility updatedAt }
        ]] .. PAGE_INFO_FIELDS .. [[ }
    }]], { pagination = self:pagination(state.page or 1, self.layout.page_size) })
    local response = data and data.readingLists
    if not response then return self:renderError(state.title, err, code) end
    state.items = {}
    for _unused, item in ipairs(response.nodes or {}) do
        state.items[#state.items + 1] = {
            id = item.id, title = item.name, summary = item.description,
            visibility = item.visibility, updated_at = item.updatedAt,
            kind = "reading_list", cover_kind = "placeholder",
        }
    end
    state.total, state.page_count = self:pageInfo(response)
    state.page = state.page or 1
    state.sort_label = _("Server order")
    self:renderEntityList(state)
end

function Browser:loadSmartLists(state)
    local data, err, code = self:graphql([[query { smartLists { id name description } }]])
    if not data or type(data.smartLists) ~= "table" then
        return self:renderError(state.title, err, code)
    end
    state.items = {}
    for _unused, item in ipairs(data.smartLists) do
        state.items[#state.items + 1] = {
            id = item.id, title = item.name, summary = item.description,
            kind = "smart_list", cover_kind = "placeholder",
        }
    end
    state.total = #state.items
    state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
    state.local_paged = true
    state.page = state.page or 1
    state.sort_label = _("Name (A–Z)")
    self:renderEntityList(state)
end

function Browser:loadLibrarySeries(state)
    local skip = ((state.page or 1) - 1) * self.layout.page_size
    local data, err, code = self:graphql([[query($id: ID!, $take: Int!, $skip: Int!) {
        libraryById(id: $id) {
            name stats { seriesCount }
            series(take: $take, skip: $skip) { id name resolvedName resolvedDescription
                createdAt mediaCount percentageCompleted }
        }
    }]], { id = state.library_id, take = self.layout.page_size, skip = skip })
    local library = data and data.libraryById
    if not library then return self:renderError(state.title, err, code) end
    state.title = library.name or state.title
    state.items = {}
    for _unused, item in ipairs(library.series or {}) do
        local mapped = Catalog.series(item)
        if mapped then mapped.kind = "series"; state.items[#state.items + 1] = mapped end
    end
    local stats = library.stats or {}
    state.total = tonumber(stats.seriesCount) or #state.items
    state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
    state.page = state.page or 1
    state.sort_label = _("Title (A–Z)")
    self:renderEntityList(state)
end

function Browser:loadSeriesBooks(state)
    local skip = ((state.page or 1) - 1) * self.layout.page_size
    local data, err, code = self:graphql([[query($id: ID!, $take: Int!, $skip: Int!) {
        seriesById(id: $id) {
            name mediaCount media(take: $take, skip: $skip) { ]] .. MEDIA_FIELDS .. [[ }
        }
    }]], { id = state.series_id, take = self.layout.page_size, skip = skip })
    local series = data and data.seriesById
    if not series then return self:renderError(state.title, err, code) end
    state.title = series.name or state.title
    state.items = {}
    for _unused, item in ipairs(series.media or {}) do
        local mapped = Catalog.media(item)
        if mapped then state.items[#state.items + 1] = mapped end
    end
    state.total = tonumber(series.mediaCount) or #state.items
    state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
    state.page = state.page or 1
    state.sort_label = _("Title (A–Z)")
    self:renderBookList(state)
end

function Browser:loadAuthorBooks(state)
    local data, err, code = self:graphql([[query($name: String!) {
        authorByName(name: $name) { name books { ]] .. MEDIA_FIELDS .. [[ } }
    }]], { name = state.author_name })
    local author = data and data.authorByName
    if not author then return self:renderError(state.title, err, code) end
    state.title = author.name or state.title
    state.items = {}
    for _unused, item in ipairs(author.books or {}) do
        local mapped = Catalog.media(item)
        if mapped then state.items[#state.items + 1] = mapped end
    end
    table.sort(state.items, function(left, right)
        return string.lower(left.title or "") < string.lower(right.title or "")
    end)
    state.total = #state.items
    state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
    state.local_paged = true
    state.page = state.page or 1
    state.sort_label = _("Title (A–Z)")
    self:renderBookList(state)
end

function Browser:loadSmartListBooks(state)
    local data, err, code = self:graphql([[query($id: ID!) {
        smartListById(id: $id) { id name description books { ]] .. MEDIA_FIELDS .. [[ } }
    }]], { id = state.smart_list_id })
    local list = data and data.smartListById
    if not list then return self:renderError(state.title, err, code) end
    state.title = list.name or state.title
    state.description = list.description
    state.items = {}
    for _unused, item in ipairs(list.books or {}) do
        local mapped = Catalog.media(item)
        if mapped then state.items[#state.items + 1] = mapped end
    end
    state.total = #state.items
    state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
    state.page = state.page or 1
    state.local_paged = true
    state.sort_label = _("Smart list order")
    self:renderBookList(state)
end

function Browser:loadSearchResults(state)
    local query, variables = Catalog.searchRequest(state.query, 50)
    local data, err, code = self:graphql(query, variables)
    if not data or type(data.searchBooks) ~= "table" then
        return self:renderError(state.title, err, code)
    end
    state.items = {}
    for _unused, item in ipairs(data.searchBooks) do
        state.items[#state.items + 1] = {
            id = tostring(item.mediaId), title = item.title,
            authors = type(item.authors) == "table" and table.concat(item.authors, ", ") or nil,
            kind = "book", cover_kind = "media",
        }
    end
    state.total = #state.items
    state.page_count = math.max(1, math.ceil(state.total / self.layout.page_size))
    state.page = state.page or 1
    state.local_paged = true
    state.sort_label = _("Title (A–Z)")
    table.sort(state.items, function(left, right)
        return string.lower(left.title or "") < string.lower(right.title or "")
    end)
    self:renderBookList(state)
end

function Browser:loadBookDetail(state)
    local data, err, code = self:graphql([[query($id: ID!) {
        mediaById(id: $id) { ]] .. MEDIA_FIELDS .. [[
            series { id name resolvedName mediaCount media(take: 4, skip: 0) { ]] .. MEDIA_FIELDS .. [[ } }
            editions { id name resolvedName extension }
        }
    }]], { id = state.book.id })
    local raw = data and data.mediaById
    if raw then
        local previous = state.book
        state.book = Catalog.media(raw) or previous
        local local_paths = {}
        for _unused, local_item in ipairs(self:onDeviceItems()) do
            local_paths[tostring(local_item.id)] = local_item.local_path
        end
        state.book.local_path = previous.local_path
            or local_paths[tostring(state.book.id)]
        state.book.extension = state.book.extension or Catalog.readerExtension(previous.extension)
        state.book.kind = "book"
        state.book.is_audiobook = state.book.is_audiobook or previous.is_audiobook
        state.book.readable_edition = state.book.is_audiobook
            and Catalog.readableEdition(raw.editions) or nil
        state.book.series_id = raw.series and raw.series.id or state.book.series_id
        state.book.series = raw.series and (raw.series.resolvedName or raw.series.name) or state.book.series
        state.book.related_series = {}
        for _unused, book in ipairs(raw.series and raw.series.media or {}) do
            if book.id ~= state.book.id then
                local mapped = Catalog.media(book)
                if mapped then mapped.kind = "book"; state.book.related_series[#state.book.related_series + 1] = mapped end
            end
        end
    elseif err then
        state.detail_error = err
    end
    local author = state.book.authors and state.book.authors:match("([^,]+)")
    if author and author ~= "" then
        local author_data = self:graphql([[query($query: String!, $limit: Int!) {
            searchBooks(query: $query, limit: $limit) { mediaId title authors }
        }]], { query = author, limit = 12 })
        local author_results = author_data and author_data.searchBooks or {}
        state.book.related_author = {}
        for _unused, result in ipairs(author_results) do
            if tostring(result.mediaId) ~= tostring(state.book.id)
                    and type(result.authors) == "table" then
                local matches = false
                for _unused, result_author in ipairs(result.authors) do
                    if string.lower(result_author) == string.lower(author) then matches = true end
                end
                if matches then
                    state.book.related_author[#state.book.related_author + 1] = {
                        id = tostring(result.mediaId), title = result.title,
                        authors = table.concat(result.authors, ", "),
                        kind = "book", cover_kind = "media",
                    }
                end
            end
        end
    end
    self:renderDetail(state)
end

function Browser:onDeviceItems()
    local result = {}
    if not self.download_dir or self.download_dir == ""
            or lfs.attributes(self.download_dir, "mode") ~= "directory" then
        return result
    end
    local DocSettings = require("docsettings")
    for name in lfs.dir(self.download_dir) do
        if name ~= "." and name ~= ".." then
            local path = self.download_dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                local suffix = name:match("%.([^%.]+)$")
                if suffix then
                    local ok, settings = pcall(DocSettings.open, DocSettings, path)
                    local id = ok and settings and settings:readSetting("coppice_media_id")
                    if type(id) == "string" and id ~= "" then
                        result[#result + 1] = {
                            id = id,
                            title = name:gsub("%.[^.]+$", ""),
                            extension = suffix,
                            local_path = path,
                            kind = "book",
                            cover_kind = "media",
                        }
                    end
                end
            end
        end
    end
    table.sort(result, function(left, right)
        return string.lower(left.title or "") < string.lower(right.title or "")
    end)
    return result
end

function Browser:ensureCacheDir()
    if lfs.attributes(self.cache_dir, "mode") == "directory" then return true end
    return util.makePath(self.cache_dir) and true or false
end

function Browser:coverPath(item)
    local name = Catalog.cacheFileName(item.cover_kind, item.id)
    if not name then return nil end
    return self.cache_dir .. "/" .. name
end

function Browser:trimCoverCache()
    if not self:ensureCacheDir() then return end
    local entries = {}
    for name in lfs.dir(self.cache_dir) do
        if name ~= "." and name ~= ".." then
            local path = self.cache_dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "file" then
                entries[#entries + 1] = {
                    name = name, path = path, size = attr.size,
                    modified = attr.modification,
                }
            end
        end
    end
    local evictions = Catalog.cacheEvictions(entries, COVER_CACHE_BYTES)
    for _unused, path in ipairs(evictions) do os.remove(path) end
end

function Browser:cachedCover(item)
    if type(item) ~= "table" or not item.id then return nil end
    if not self:ensureCacheDir() then return nil end
    local path = self:coverPath(item)
    if not path then return nil end
    if lfs.attributes(path, "mode") ~= "file" then
        local url = Catalog.coverUrl(self.api.base, item)
        if not url then return nil end
        local ok = self.api:downloadAsset(url, path)
        if not ok then return nil end
    end
    local now = os.time()
    if lfs.touch then lfs.touch(path, now, now) end
    self:trimCoverCache()
    return lfs.attributes(path, "mode") == "file" and path or nil
end

-- The plugin's own directory, for bundled icons.
local PLUGIN_DIR = ((debug.getinfo(1, "S").source or ""):gsub("^@", "")):match("^(.*)/[^/]*$") or "."

-- A cover (or text placeholder) sitting on the bottom of its slot, with the
-- reading progress bar directly under the image at the image's width.
-- Books use a portrait slot; audiobook covers are square and carry a small
-- headphones chip. `progress` is nil (no bar), false (reserve the space so a
-- row stays level), or a 0..100 percentage.
function Browser:coverWidget(item, width, height, progress)
    local bar_height = Screen:scaleBySize(6)
    local bar_gap = Screen:scaleBySize(3)
    local image_height = progress ~= nil and (height - bar_height - bar_gap) or height
    local cover
    local path = self:cachedCover(item)
    if path then
        -- A square no wider than a typical 2:3 book cover at this height,
        -- so books read as the larger covers and every bottom stays level.
        local box_height = item.is_audiobook
            and math.min(width, math.floor(image_height * 2 / 3)) or image_height
        cover = ImageWidget:new{
            file = path,
            width = width,
            height = box_height,
            scale_factor = 0,
            -- Covers are already cached on disk. KOReader's shared image
            -- cache holds decoded bitmaps and aborts on one larger than its
            -- whole budget (a 1448x2045 server "thumbnail" is ~12 MB).
            file_do_cache = false,
        }
        if item.is_audiobook then
            local size = cover:getSize()
            local icon_size = Screen:scaleBySize(14)
            local badge = FrameContainer:new{
                padding = Screen:scaleBySize(2),
                padding_left = Screen:scaleBySize(3),
                padding_right = Screen:scaleBySize(3),
                bordersize = 1,
                background = Blitbuffer.COLOR_WHITE,
                IconWidget:new{
                    file = PLUGIN_DIR .. "/icons/headphones.svg",
                    width = icon_size,
                    height = icon_size,
                },
            }
            local inset = Screen:scaleBySize(4)
            local badge_size = badge:getSize()
            badge.overlap_offset = { inset, math.max(0, size.h - badge_size.h - inset) }
            cover = OverlapGroup:new{
                dimen = Geom:new{ w = size.w, h = size.h },
                cover,
                badge,
            }
        end
    else
        local inset = Screen:scaleBySize(8)
        local text = textWidget(item.title or item.name or _("Cover unavailable"),
            math.max(1, width - inset * 2), math.max(1, image_height - inset * 2), 16, "center", true)
        cover = FrameContainer:new{
            width = math.max(1, width - inset),
            height = math.max(1, image_height - inset),
            padding = Screen:scaleBySize(4),
            bordersize = 1,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{
                    w = math.max(1, width - inset * 2),
                    h = math.max(1, image_height - inset * 2),
                },
                text,
            },
        }
    end
    local stack = { align = "center", cover }
    if progress ~= nil then
        stack[#stack + 1] = VerticalSpan:new{ width = bar_gap }
        if progress then
            stack[#stack + 1] = ProgressWidget:new{
                width = cover:getSize().w,
                height = bar_height,
                percentage = progress / 100,
                radius = 0,
                margin_h = 0,
                margin_v = 0,
                bordersize = 1,
            }
        else
            stack[#stack + 1] = VerticalSpan:new{ width = bar_height }
        end
    end
    return BottomContainer:new{
        dimen = Geom:new{ w = width, h = height },
        VerticalGroup:new(stack),
    }
end

function Browser:coverTile(item, width, cover_height, on_select, options, on_hold)
    options = options or {}
    local pad = Screen:scaleBySize(5)
    local inner_width = math.max(1, width - 2 * pad)
    local title_height = options.title_height or 0
    local title_gap = title_height > 0 and Screen:scaleBySize(4) or 0
    local has_progress = item.progression ~= nil and options.show_progress ~= false
    local progress
    if options.progress_space then
        progress = has_progress and (Catalog.progressPercent(item.progression) or 0) or false
    end
    local content_height = cover_height + title_gap + title_height
    local children = { self:coverWidget(item, inner_width, cover_height, progress) }
    if title_height > 0 then
        children[#children + 1] = VerticalSpan:new{ width = title_gap }
        children[#children + 1] = textWidget(item.title or item.name or "(untitled)",
            inner_width, title_height, 15, "center", true)
    end
    local frame = FrameContainer:new{
        width = width,
        height = content_height + 2 * pad,
        padding = pad,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_width, h = content_height },
            VerticalGroup:new(children),
        },
    }
    local tile = InputContainer:new{
        frame,
        key_events = {},
        ges_events = {},
    }
    tile.dimen = frame:getSize()
    tile.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = tile.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = tile.dimen } },
    }
    function tile:onTapSelect()
        on_select(item)
        return true
    end
    function tile:onHoldSelect()
        if on_hold then on_hold(item) else on_select(item) end
        return true
    end
    return tile
end

function Browser:bookProgressText(item)
    local percent = Catalog.progressPercent(item.progression)
    local text = percent and (tostring(percent) .. "%") or ""
    if item.page and item.pages then
        text = text ~= "" and (text .. " · ") or ""
        text = text .. T(_("p. %1/%2"), item.page, item.pages)
    elseif item.page then
        text = text ~= "" and (text .. " · ") or ""
        text = text .. T(_("p. %1"), item.page)
    end
    return text
end

function Browser:openItem(item)
    if item.kind == "library" then
        return self:openScreen({ kind = "library_series", title = item.title, library_id = item.id, page = 1 })
    elseif item.kind == "series" then
        return self:openScreen({ kind = "series_books", title = item.title, series_id = item.id, page = 1 })
    elseif item.kind == "author" then
        return self:openScreen({ kind = "author_books", title = item.title, author_name = item.title, page = 1 })
    elseif item.kind == "reading_list" then
        return self:openScreen({ kind = "reading_list_detail", title = item.title, item = item })
    elseif item.kind == "smart_list" then
        return self:openScreen({ kind = "smart_list_books", title = item.title, smart_list_id = item.id, page = 1 })
    elseif item.kind == "book" or item.id then
        local book = item.kind == "book" and item or item
        return self:openScreen({ kind = "detail", title = book.title, book = book })
    end
end

function Browser:search()
    local dialog
    local submitted = false
    local function submit()
        if submitted then return end
        submitted = true
        local query = dialog:getInputText()
        UIManager:close(dialog)
        if not query or query:gsub("%s", "") == "" then return end
        self:openScreen({
            kind = "search", title = T(_("Search: %1"), query), query = query, page = 1,
        })
    end
    dialog = InputDialog:new{
        title = _("Search Coppice"),
        input_hint = _("title, author, summary or genre"),
        allow_newline = false,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = submit },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:changePage(delta)
    return self:goToPage((tonumber(self.screen_state.page) or 1) + delta)
end

function Browser:goToPage(page)
    local state = self.screen_state
    local page_count = math.max(1, tonumber(state.page_count) or 1)
    local next_page = math.max(1, math.min(page_count, tonumber(page) or 1))
    if next_page == state.page then return end
    state.page = next_page
    self:loadCurrentScreen()
end

function Browser:toggleListMode()
    self.list_mode = not self.list_mode
    self:renderCurrentData()
end

function Browser:renderCurrentData()
    local state = self.screen_state
    if state.kind == "home" then return self:renderHome(state.data or {}) end
    if state.kind == "detail" then return self:renderDetail(state) end
    if state.kind == "reading_list_detail" then return self:renderReadingListDetail(state) end
    if state.items and (state.kind == "libraries" or state.kind == "series" or state.kind == "authors"
            or state.kind == "reading_lists" or state.kind == "smart_lists" or state.kind == "library_series") then
        return self:renderEntityList(state)
    end
    return self:renderBookList(state)
end

function Browser:renderLoading(title)
    local width = Screen:getWidth() - 2 * self.layout.margin
    self:setContent(VerticalGroup:new{
        self:header(title, false),
        VerticalSpan:new{ width = 36 },
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = 100 },
            textWidget(_("Loading Coppice library…"), width, 72, 22, "center", false),
        },
    })
end

-- The top bar: back/close on the left, search and home on the right, all the
-- same size and centred on one line, with the title centred between them.
-- Two icon slots are reserved on each side so the title stays centred.
function Browser:header(title, is_home, subtitle)
    local width = Screen:getWidth() - 2 * self.layout.margin
    local icon_size = Screen:scaleBySize(30)
    local padding = Screen:scaleBySize(10)
    local slot = icon_size + 2 * padding
    local function iconButton(name, callback)
        return IconButton:new{
            icon = name,
            width = icon_size,
            height = icon_size,
            padding = padding,
            callback = callback,
            allow_flash = false,
            show_parent = self,
        }
    end
    local left = iconButton(is_home and "close" or "chevron.left", function()
        if is_home then self:close() else self:back() end
    end)
    local right = HorizontalGroup:new{
        align = "center",
        iconButton("appbar.search", function() self:search() end),
        iconButton("home", function() self:home() end),
    }
    local title_width = math.max(1, width - 4 * slot)
    local titles = VerticalGroup:new{
        align = "center",
        singleLine(title or _("Coppice"), title_width, 22, true),
    }
    if subtitle and subtitle ~= "" then
        titles[#titles + 1] = singleLine(subtitle, title_width, 14, false)
    end
    local bar = Geom:new{ w = width, h = math.max(slot, titles:getSize().h + padding) }
    return VerticalGroup:new{
        align = "left",
        OverlapGroup:new{
            dimen = bar:copy(),
            LeftContainer:new{ dimen = bar:copy(), left },
            CenterContainer:new{ dimen = bar:copy(), titles },
            RightContainer:new{ dimen = bar:copy(), right },
        },
        -- Status (time, sync queue, Wi-Fi, server, battery) is part of the top
        -- bar so it stays pinned on every screen, above the divider.
        self:statusRow(self:homeStatus(self.server_reachable), width),
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        LineWidget:new{ dimen = Geom:new{ w = width, h = Size.line.thick } },
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
    }
end

function Browser:sectionHeader(title, width, control)
    if control then
        local height = math.max(control:getSize().h, Screen:scaleBySize(28))
        local dimen = Geom:new{ w = width, h = height }
        return OverlapGroup:new{
            dimen = dimen:copy(),
            LeftContainer:new{
                dimen = dimen:copy(),
                singleLine(title, width - control:getSize().w - 8, 20, true),
            },
            RightContainer:new{ dimen = dimen:copy(), control },
        }
    end
    return singleLine(title, width, 20, true)
end

function Browser:readLocalStatistics()
    local function query()
        local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        if lfs.attributes(path, "mode") ~= "file" then return nil end
        local SQLite = require("lua-ljsqlite3/init")
        local database = SQLite.open(path, "ro")
        if not database then return nil end
        local ok, rows = pcall(database.exec, database, Catalog.statisticsQuery(), "hik")
        pcall(database.close, database)
        if not ok or type(rows) ~= "table" then return nil end
        return rows
    end
    local ok, rows = pcall(query)
    if not ok or type(rows) ~= "table" then return nil end
    return Catalog.readingStats(rows)
end

function Browser:recentHistory(titles)
    local ok, history = pcall(require, "readhistory")
    if not ok or type(history) ~= "table" or type(history.hist) ~= "table" then return {} end
    local ok_settings, DocSettings = pcall(require, "docsettings")
    local items, seen = {}, {}
    for _unused, entry in ipairs(history.hist) do
        local path = type(entry.file) == "string" and entry.file or nil
        if path and not seen[path] and lfs.attributes(path, "mode") == "file" then
            seen[path] = true
            local id
            if ok_settings and DocSettings then
                local settings_ok, settings = pcall(DocSettings.open, DocSettings, path)
                if settings_ok and settings then
                    local read_ok, value = pcall(settings.readSetting, settings, "coppice_media_id")
                    if read_ok and type(value) == "string" and value ~= "" then id = value end
                end
            end
            items[#items + 1] = {
                id = id,
                title = (id and titles[tostring(id)]) or entry.text
                    or path:match("([^/]+)$") or path,
                local_path = path,
                kind = "book",
                cover_kind = "media",
                time = entry.time,
            }
            if #items >= self.layout.columns then break end
        end
    end
    return items
end

function Browser:recentAnnotations(titles, cache_only)
    if type(self.on_recent_annotations) ~= "function" then return {} end
    local ok, items = pcall(self.on_recent_annotations, titles or {}, cache_only == true)
    if not ok or type(items) ~= "table" then return {} end
    local local_paths = {}
    for _unused, item in ipairs(self:onDeviceItems()) do
        local_paths[tostring(item.id)] = item.local_path
    end
    for _unused, item in ipairs(items) do
        if type(item) == "table" then
            local id = item.book_id or item.media_id
            item.title = (id and titles and titles[tostring(id)])
                or item.book_title or item.title
            item.local_path = item.local_path
                or (id and local_paths[tostring(id)])
            item.source = item.source or Catalog.annotationSource(item)
        end
    end
    local recent = Catalog.recentAnnotations(items, 4)
    for _unused, item in ipairs(recent) do
        item.source = item.source or Catalog.annotationSource(item)
        item.time_label = Catalog.relativeTime(item.updated_at)
    end
    return recent
end

-- Status facts for Home's status row. Battery is left out on devices
-- without one (a desktop reports none, or 0 %).
function Browser:homeStatus(server_reachable)
    local status = { time = os.date("%H:%M"), server = server_reachable == true }
    local has_battery = true
    if type(Device.hasBattery) == "function" then
        local ok, value = pcall(Device.hasBattery, Device)
        has_battery = ok and value and true or false
    end
    local power_ok, power = pcall(Device.getPowerDevice, Device)
    if has_battery and power_ok and power and type(power.getCapacityHW) == "function" then
        local battery_ok, capacity = pcall(power.getCapacityHW, power)
        capacity = battery_ok and tonumber(capacity) or nil
        if capacity and capacity > 0 then status.battery = math.floor(capacity + 0.5) end
    end
    local wifi_ok, wifi = pcall(NetworkMgr.getWifiState, NetworkMgr)
    if not wifi_ok or wifi == nil then wifi = NetworkMgr.is_wifi_on end
    if wifi ~= nil then status.wifi = wifi == true end
    status.pending = 0
    if type(self.on_pending_count) == "function" then
        local pending_ok, value = pcall(self.on_pending_count)
        if pending_ok then status.pending = math.max(0, tonumber(value) or 0) end
    end
    return status
end

-- One slim row: time at left; unsynced count, Wi-Fi, server and battery at
-- right as icons and short text.
function Browser:statusRow(status, width)
    local height = Screen:scaleBySize(22)
    local icon_size = Screen:scaleBySize(16)
    local gap = Screen:scaleBySize(8)
    local right = { align = "center" }
    local function push(widget)
        if #right > 0 then right[#right + 1] = HorizontalSpan:new{ width = gap } end
        right[#right + 1] = widget
    end
    if (status.pending or 0) > 0 then
        push(singleLine(T(_("%1 to sync"), status.pending), math.floor(width / 3), 12, false))
    end
    if status.wifi ~= nil then
        push(IconWidget:new{ icon = status.wifi and "wifi.open.100" or "wifi.open.0",
            width = icon_size, height = icon_size })
    end
    push(HorizontalGroup:new{
        align = "center",
        IconWidget:new{ icon = status.server and "check" or "notice-warning",
            width = icon_size, height = icon_size },
        HorizontalSpan:new{ width = Screen:scaleBySize(3) },
        singleLine(status.server and _("Server") or _("Offline"), math.floor(width / 4), 12, false),
    })
    if status.battery then push(singleLine(status.battery .. "%", math.floor(width / 6), 12, false)) end
    local dimen = Geom:new{ w = width, h = height }
    return OverlapGroup:new{
        dimen = dimen:copy(),
        LeftContainer:new{ dimen = dimen:copy(), singleLine(status.time or "", math.floor(width / 3), 13, true) },
        RightContainer:new{ dimen = dimen:copy(), HorizontalGroup:new(right) },
    }
end

-- Library, on-device and (when KOReader statistics exist) reading numbers in
-- one row, divided by thin vertical lines instead of boxes.
function Browser:statStrip(data, width)
    -- Reading numbers first (when KOReader statistics exist), then library
    -- and on-device counts. Every cell is two lines: value, then label.
    local items = {}
    local stats = data.reading_stats
    if type(stats) == "table" then
        items[#items + 1] = { value = Catalog.durationLabel(stats.today_minutes), label = _("TODAY") }
        items[#items + 1] = { value = Catalog.durationLabel(stats.week_minutes), label = _("7 DAYS") }
        items[#items + 1] = { value = T(_("%1 d"), stats.streak_days or 0), label = _("STREAK") }
    end
    items[#items + 1] = { value = data.library_count or "—", label = _("LIBRARY") }
    items[#items + 1] = { value = data.on_device_count or 0, label = _("ON DEVICE") }
    local divider_width = math.max(1, math.floor(Size.line.thin or 1))
    local column = math.floor((width - divider_width * (#items - 1)) / #items)
    local height = Screen:scaleBySize(46)
    local row = { align = "center" }
    for index, item in ipairs(items) do
        if index > 1 then
            row[#row + 1] = LineWidget:new{
                dimen = Geom:new{ w = divider_width, h = height - Screen:scaleBySize(12) },
                background = Blitbuffer.COLOR_DARK_GRAY,
            }
        end
        row[#row + 1] = CenterContainer:new{
            dimen = Geom:new{ w = column, h = height },
            VerticalGroup:new{
                align = "center",
                singleLine(tostring(item.value), column - 6, 18, true),
                singleLine(item.label, column - 6, 10, false),
            },
        }
    end
    return HorizontalGroup:new(row)
end

function Browser:openLocalFile(item)
    if type(item) ~= "table" or type(item.local_path) ~= "string"
            or lfs.attributes(item.local_path, "mode") ~= "file" then
        return self:openItem(item or {})
    end
    if self.on_open_file then
        self.on_open_file(item.local_path, item)
    elseif self.on_download_complete then
        self.on_download_complete(item.local_path, item)
    else
        self:openItem(item)
    end
end

function Browser:openContinue(item)
    if Catalog.continueTapAction(item,
            item and item.local_path and lfs.attributes(item.local_path, "mode") == "file") == "open" then
        return self:openLocalFile(item)
    end
    return self:openItem(item)
end

function Browser:homePager(page, pages, width, callback)
    if pages <= 1 then return nil end
    local button_width = Screen:scaleBySize(48)
    local height = Screen:scaleBySize(48)
    local gap = Screen:scaleBySize(6)
    local page_width = width - 2 * button_width - 2 * gap
    return spacedRow({
        makeButton("‹", function() callback(page - 1) end, button_width, height, { size = 22 , bordersize = 0 }),
        CenterContainer:new{
            dimen = Geom:new{ w = page_width, h = height },
            singleLine(T(_("Page %1 of %2"), page, pages), page_width, 14, false),
        },
        makeButton("›", function() callback(page + 1) end, button_width, height, { size = 22 , bordersize = 0 }),
    }, gap)
end

function Browser:changeContinuePage(data, page)
    data.continue_page = math.max(1, math.min(data.continue_page_count or 1, page))
    self.home_continue_page = data.continue_page
    self.screen_state.data = data
    self:renderHome(data)
end

function Browser:changeRecentPage(data, page)
    data.recent_page = math.max(1, math.min(data.recent_page_count or 1, page))
    self.home_recent_page = data.recent_page
    self.screen_state.data = data
    self:renderHome(data)
    self:loadHomeWhenConnected()
end

-- Headphones button: outlined while audiobooks are listed; tap to hide or
-- show them. The choice is kept and shared by Home and the book grids.
function Browser:audioToggle(show_audio, on_change)
    local icon_size = Screen:scaleBySize(20)
    local frame = FrameContainer:new{
        padding = Screen:scaleBySize(6),
        -- Same border width in both states so the line never shifts; it is
        -- simply drawn white while audiobooks are hidden.
        bordersize = Size.border.thick,
        color = show_audio and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
        radius = Size.radius.button,
        background = Blitbuffer.COLOR_WHITE,
        IconWidget:new{
            file = PLUGIN_DIR .. "/icons/headphones.svg",
            width = icon_size,
            height = icon_size,
            alpha = true,
        },
    }
    local button = InputContainer:new{ frame, key_events = {}, ges_events = {} }
    button.dimen = frame:getSize()
    button.ges_events = { TapToggle = { GestureRange:new{ ges = "tap", range = button.dimen } } }
    function button:onTapToggle()
        G_reader_settings:saveSetting("coppice_show_audio", not show_audio)
        on_change()
        return true
    end
    return button
end

function Browser:continueRow(data, width)
    local show_audio = self:showAudio()
    local continues = {}
    for _unused, item in ipairs(data.continues or {}) do
        if show_audio or not item.is_audiobook then continues[#continues + 1] = item end
    end
    local count = show_audio and (tonumber(data.progress_count) or #continues) or #continues
    local heading = count > 0 and T(_("Continue reading (%1)"), count) or _("Continue reading")
    local children = { self:sectionHeader(heading, width, self:audioToggle(show_audio, function()
        data.continue_page = 1
        self:renderHome(data)
    end)) }
    local items, page, pages = Catalog.page(continues,
        data.continue_page or 1, self.layout.columns)
    data.continue_page, data.continue_page_count = page, pages
    if #items == 0 then
        children[#children + 1] = VerticalSpan:new{ width = 4 }
        children[#children + 1] = singleLine(_("Nothing in progress yet."), width, 15, false)
    else
        children[#children + 1] = VerticalSpan:new{ width = 6 }
        local rows = self:gridRows(items, function(item) self:openContinue(item) end,
            function(item) self:openItem(item) end, {
                title_height = Screen:scaleBySize(36),
                progress_space = true,
                width = width,
                cover_scale = self.home_cover_scale,
            })
        for _unused, row in ipairs(rows) do children[#children + 1] = row end
        local pager = self:homePager(page, pages, width, function(target)
            self:changeContinuePage(data, target)
        end)
        if pager then
            children[#children + 1] = VerticalSpan:new{ width = 4 }
            children[#children + 1] = pager
        end
    end
    children.align = "left"
    return VerticalGroup:new(children)
end

function Browser:recentlyOpenedRow(data, width)
    local children = { self:sectionHeader(_("Recently opened on this device"), width) }
    if not data.recent_history or #data.recent_history == 0 then
        children[#children + 1] = VerticalSpan:new{ width = 4 }
        children[#children + 1] = singleLine(_("No recently opened books on this device."),
            width, 15, false)
    else
        children[#children + 1] = VerticalSpan:new{ width = 6 }
        local recent = {}
        for index = 1, math.min(#data.recent_history, self.layout.columns) do
            recent[index] = data.recent_history[index]
        end
        if self.home_compact then
            -- Short screens: one tappable title line per book.
            for _unused, item in ipairs(recent) do
                children[#children + 1] = makeButton(item.title or _("(untitled)"), function()
                    self:openLocalFile(item)
                end, width, Screen:scaleBySize(40), {
                    size = 15, align = "left", bold = false, bordersize = 0,
                    padding = Screen:scaleBySize(4),
                })
            end
            children.align = "left"
            return VerticalGroup:new(children)
        end
        local rows = self:gridRows(recent, function(item)
            self:openLocalFile(item)
        end, nil, {
            title_height = Screen:scaleBySize(36),
            progress_space = true,
            show_progress = false,
            width = width,
            cover_scale = self.home_cover_scale,
        })
        for _unused, row in ipairs(rows) do children[#children + 1] = row end
    end
    children.align = "left"
    return VerticalGroup:new(children)
end

function Browser:recentlyAddedRow(data, width)
    local title = _("Recently added")
    local children = { self:sectionHeader(title, width) }
    if not data.recent or #data.recent == 0 then
        children[#children + 1] = VerticalSpan:new{ width = 4 }
        children[#children + 1] = singleLine(_("No recent books yet."), width, 15, false)
    else
        children[#children + 1] = VerticalSpan:new{ width = 6 }
        local rows = self:gridRows(data.recent, function(item) self:openItem(item) end,
            nil, { show_progress = false, width = width, cover_scale = self.home_cover_scale })
        for _unused, row in ipairs(rows) do children[#children + 1] = row end
        local pager = self:homePager(data.recent_page or 1,
            data.recent_page_count or 1, width, function(target)
                self:changeRecentPage(data, target)
            end)
        if pager then
            children[#children + 1] = VerticalSpan:new{ width = 4 }
            children[#children + 1] = pager
        end
    end
    children.align = "left"
    return VerticalGroup:new(children)
end

-- Highlight colours as KOReader draws them, plus Liseur's pink.
local EXTRA_HIGHLIGHT_COLORS = { pink = "#FF66AA" }

-- A highlight's chip colours: fill (mixed with white so black text stays
-- readable; light gray on grayscale screens) and border (the full colour).
local function highlightTint(name)
    if type(name) ~= "string" then return nil end
    local hex = (Blitbuffer.HIGHLIGHT_COLORS or {})[name:lower()]
        or EXTRA_HIGHLIGHT_COLORS[name:lower()]
    if not hex or not Blitbuffer.ColorRGB32 then return nil end
    local function channel(offset, weight)
        local value = tonumber(hex:sub(offset, offset + 1), 16) or 255
        return math.floor(value * weight + 255 * (1 - weight))
    end
    local tint = Blitbuffer.ColorRGB32(channel(2, 0.45), channel(4, 0.45), channel(6, 0.45), 0xFF)
    local full = Blitbuffer.ColorRGB32(channel(2, 1), channel(4, 1), channel(6, 1), 0xFF)
    return tint, full
end

-- One highlight or note, without a box, at a fixed height so lists page
-- evenly:
--   Book title                                   Liseur · 2h ago
--   [passage, shaded in its highlight colour, up to two lines]
--   note, one line (empty for a plain highlight)
function Browser:annotationCard(item, width)
    local padding = Screen:scaleBySize(6)
    local line_height = Screen:scaleBySize(22)
    local gap = Screen:scaleBySize(8)
    local is_note = item.kind == "note" or (type(item.body) == "string" and item.body ~= "")
    local fill, border = highlightTint(item.color)
    local chip_text = singleLine(is_note and _("Note") or _("Highlight"), Screen:scaleBySize(90), 11, false)
    local chip = FrameContainer:new{
        padding = Screen:scaleBySize(1),
        padding_left = Screen:scaleBySize(5),
        padding_right = Screen:scaleBySize(5),
        bordersize = 1,
        -- Uncoloured notes (Home notes have no colour) get a plain chip.
        color = border or Blitbuffer.COLOR_BLACK,
        background = fill or Blitbuffer.COLOR_WHITE,
        chip_text,
    }
    local source = item.source or Catalog.annotationSource(item)
    local when = item.time_label or Catalog.relativeTime(item.updated_at)
    local meta = table.concat({ source, when ~= "" and when or nil }, " · ")
    local meta_widget = singleLine(meta, math.floor(width * 0.42), 12, false)
    local title_width = math.max(1, width - chip:getSize().w - meta_widget:getSize().w - 2 * gap)
    local top_line = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = line_height },
        LeftContainer:new{
            dimen = Geom:new{ w = width, h = line_height },
            HorizontalGroup:new{
                align = "center",
                chip,
                HorizontalSpan:new{ width = gap },
                singleLine(item.title or _("Unknown book"), title_width, 14, true),
            },
        },
        RightContainer:new{ dimen = Geom:new{ w = width, h = line_height }, meta_widget },
    }
    local excerpt = Catalog.truncateText(item.excerpt or item.text or "", 160)
    local note = Catalog.truncateText(item.body or item.note or "", 90)
    local content = VerticalGroup:new{
        align = "left",
        top_line,
        VerticalSpan:new{ width = Screen:scaleBySize(3) },
        textWidget(excerpt ~= "" and ("“" .. excerpt .. "”") or "", width,
            Screen:scaleBySize(38), 14, "left", false),
        VerticalSpan:new{ width = Screen:scaleBySize(2) },
        textWidget(note, width, Screen:scaleBySize(20), 13, "left", true),
    }
    local frame = FrameContainer:new{
        width = width,
        padding = 0,
        padding_top = padding,
        padding_bottom = padding,
        bordersize = 0,
        content,
    }
    local card = InputContainer:new{ frame, key_events = {}, ges_events = {} }
    card.dimen = frame:getSize()
    card.ges_events = {
        TapAnnotation = { GestureRange:new{ ges = "tap", range = card.dimen } },
    }
    card.browser = self
    function card:onTapAnnotation()
        if self.browser.on_open_annotation then self.browser.on_open_annotation(item) end
        return true
    end
    return card
end

-- A thin gray rule between highlight entries.
function Browser:annotationDivider(width)
    return LineWidget:new{
        dimen = Geom:new{ w = width, h = math.max(1, math.floor(Size.line.thin or 1)) },
        background = Blitbuffer.COLOR_GRAY,
    }
end

-- Every highlight and note on the server, newest first, a screenful per page.
function Browser:loadAllAnnotations(state)
    local card_height = Screen:scaleBySize(22 + 3 + 38 + 2 + 20 + 12)
    local per_page = math.max(3, math.floor((Screen:getHeight() - Screen:scaleBySize(230))
        / (card_height + Screen:scaleBySize(6))))
    state.page = math.max(1, tonumber(state.page) or 1)
    local data, err, code = self:graphql(Catalog.recentAnnotationsRequest(per_page, state.page))
    local page = data and data.annotations
    if type(page) ~= "table" then
        return self:renderError(state.title, err, code)
    end
    state.total = tonumber(page.total) or 0
    state.page_count = math.max(1, math.ceil(state.total / per_page))
    state.items = {}
    for _unused, entry in ipairs(type(page.items) == "table" and page.items or {}) do
        local mapped = Catalog.serverAnnotation(entry)
        if mapped then state.items[#state.items + 1] = mapped end
    end
    local width = Screen:getWidth() - 2 * self.layout.margin
    local header = self:header(state.title, false,
        T(_("%1 highlights & notes · Newest first"), state.total))
    local body = { align = "left" }
    if #state.items == 0 then
        body[1] = singleLine(_("No highlights or notes yet."), width, 18, false)
    end
    for index, item in ipairs(state.items) do
        if index > 1 then body[#body + 1] = self:annotationDivider(width) end
        body[#body + 1] = self:annotationCard(item, width)
    end
    self:renderPagedScreen(header, VerticalGroup:new(body),
        self:pagingControls(state, width), width)
end

function Browser:recentAnnotationsRow(data, width)
    local see_all
    do
        see_all = makeButton(_("See all"), function()
            self:openScreen({ kind = "all_annotations", title = _("Highlights & notes"), page = 1 })
        end,
            Screen:scaleBySize(82), Screen:scaleBySize(48), { size = 13, bordersize = 0 })
    end
    local children = { self:sectionHeader(_("Recent highlights & notes"), width, see_all) }
    if not data.annotations or #data.annotations == 0 then
        children[#children + 1] = VerticalSpan:new{ width = 4 }
        children[#children + 1] = singleLine(_("No recent highlights or notes yet."),
            width, 15, false)
    else
        for index, item in ipairs(data.annotations) do
            if index > (self.home_max_annotations or 4) then break end
            children[#children + 1] = self:annotationDivider(width)
            children[#children + 1] = self:annotationCard(item, width)
        end
    end
    children.align = "left"
    return VerticalGroup:new(children)
end

function Browser:browseCategories(width)
    local categories = {
        { _("In progress"), "in_progress" },
        { _("On device"), "on_device" },
        { _("Libraries"), "libraries" },
        { _("All books"), "all_books" },
        { _("Authors"), "authors" },
        { _("Series"), "series" },
        { _("Reading lists"), "reading_lists" },
        { _("Smart lists"), "smart_lists" },
    }
    -- Recently added and remote notes are already on Home (its Recently added
    -- row and the highlights' "See all"), so Browse stays a 3 × 3 grid.
    if self.on_sync_annotations then categories[#categories + 1] = { _("Sync annotations now"), "sync" } end
    local columns = 3
    local gap = Screen:scaleBySize(8)
    local button_height = Screen:scaleBySize(54)
    local button_options = {
        size = 15, padding = Screen:scaleBySize(6),
        bordersize = Size.border.thick, radius = Size.radius.button,
    }
    local button_width = math.floor((width - gap * (columns - 1)) / columns)
    -- A thick-bordered Button can draw wider than asked; shrink by the
    -- measured overshoot so the grid never exceeds `width`.
    local probe = makeButton("", function() end, button_width, button_height, button_options)
    button_width = button_width - math.max(0, probe:getSize().w - button_width)
    local rows, current = {}, {}
    for index, category in ipairs(categories) do
        local category_title, category_kind = category[1], category[2]
        current[#current + 1] = makeButton(category_title, function()
            if category_kind == "sync" then
                self.on_sync_annotations()
            elseif category_kind == "notes" then
                self.on_remote_notes()
            else
                self:openScreen({
                    kind = category_kind, title = category_title, page = 1,
                    sort_label = category_kind == "recent_books"
                        and _("Recently added") or _("Title (A–Z)"),
                })
            end
        end, button_width, button_height, button_options)
        if #current == columns or index == #categories then
            local row = spacedRow(current, gap)
            if #current < columns then
                local used = row:getSize().w
                local side = math.floor((width - used) / 2)
                row = HorizontalGroup:new{
                    HorizontalSpan:new{ width = side },
                    row,
                    HorizontalSpan:new{ width = width - used - side },
                }
            end
            rows[#rows + 1] = row
            current = {}
        end
    end
    local children = {}
    for index, row in ipairs(rows) do
        if index > 1 then children[#children + 1] = VerticalSpan:new{ width = gap } end
        children[#children + 1] = row
    end
    children.align = "left"
    return VerticalGroup:new(children)
end

-- Home is one column exactly as wide as the screen. When it is taller than
-- the screen it scrolls one full screen per swipe, snapping to the top of a
-- section so no section is left half-cut at the top.
function Browser:renderHome(data)
    data = data or {}
    self.screen_state.data = data
    local header = self:header(_("Coppice"), true)
    local full_width = Screen:getWidth() - 2 * self.layout.margin
    local content_height = math.max(1,
        Screen:getHeight() - header:getSize().h - 2 * self.layout.margin)
    -- Home fits one screen, or at most two when it scrolls: on short screens
    -- the cover rows shrink and fewer highlights show until it fits.
    -- Each step: cover scale, highlights shown, compact text rows.
    local fits = {
        { 1, 4, false }, { 0.85, 4, false }, { 0.75, 3, false },
        { 0.75, 3, true }, { 0.65, 3, true }, { 0.55, 3, true }, { 0.45, 3, true },
    }
    local children, group
    for index, fit in ipairs(fits) do
        self.home_cover_scale, self.home_max_annotations, self.home_compact = fit[1], fit[2], fit[3]
        children = self:homeSections(data, full_width)
        group = VerticalGroup:new(children)
        if group:getSize().h > content_height then
            -- A vertical scroll bar takes 3 × its width from the view; any
            -- content wider than what is left turns on sideways scrolling,
            -- which Home must never have.
            local allowed = full_width - 3 * ScrollableContainer.scroll_bar_width
            local width = allowed
            for _unused = 1, 3 do
                children = self:homeSections(data, width)
                group = VerticalGroup:new(children)
                local overflow = group:getSize().w - allowed
                if overflow <= 0 then break end
                width = width - overflow
            end
        end
        if group:getSize().h <= 2 * content_height or index == #fits then break end
    end
    -- Swipe steps are the rows inside each section (its heading, each card
    -- row, its pager), so a swipe backs up by at most one row instead of a
    -- whole section and two screens of content stay two swipes.
    local steps, y = {}, 0
    local function addSteps(widget, top)
        local height = widget:getSize().h
        if height <= 0 or widget.is_spacer then return end
        local inner, offset = false, top
        if widget.align and widget[1] and not widget.dimen then
            for _unused, row in ipairs(widget) do
                local row_height = row.getSize and row:getSize().h or 0
                -- A VerticalSpan (KOReader keeps its height in `width`) has no
                -- children, text, or dimen, and reports zero width.
                local spacer = row[1] == nil and row.text == nil and row.dimen == nil
                    and row.getSize and row:getSize().w == 0
                if row_height > 0 and not spacer then
                    steps[#steps + 1] = { top = offset, bottom = offset + row_height - 1 }
                    inner = true
                end
                offset = offset + row_height
            end
        end
        if not inner then steps[#steps + 1] = { top = top, bottom = top + height - 1 } end
    end
    for _unused, child in ipairs(children) do
        addSteps(child, y)
        y = y + child:getSize().h
    end
    -- The scroll view anchors its first screen on the first step; starting
    -- that step at 0 keeps the space above the first section visible.
    if steps[1] then steps[1].top = 0 end
    -- Never snap below the last full screen: the final swipe ends exactly at
    -- the bottom of Home instead of scrolling a lone row to the top.
    local last_top = y - content_height
    if last_top > 0 then
        local clamped = {}
        for _unused, step in ipairs(steps) do
            if step.top < last_top then clamped[#clamped + 1] = step end
        end
        clamped[#clamped + 1] = { top = last_top, bottom = y - 1 }
        steps = clamped
    end
    local scroll = ScrollableContainer:new{
        dimen = Geom:new{ w = full_width, h = content_height },
        show_parent = self,
        swipe_full_view = true,
        step_scroll_grid = steps,
        group,
    }
    self:setContent(VerticalGroup:new{ align = "left", header, scroll })
end

-- Home's sections, top to bottom, each exactly `width` wide.
function Browser:homeSections(data, width)
    local children = { align = "left" }
    local function add(widget, space)
        if widget then children[#children + 1] = widget end
        if space then
            if self.home_compact then space = math.ceil(space / 2) end
            local spacer = VerticalSpan:new{ width = Screen:scaleBySize(space) }
            spacer.is_spacer = true
            children[#children + 1] = spacer
        end
    end
    -- Space under the top bar; kept whole even in compact mode.
    local top_space = VerticalSpan:new{ width = Screen:scaleBySize(20) }
    top_space.is_spacer = true
    children[#children + 1] = top_space
    add(self:statStrip(data, width), 12)
    add(self:continueRow(data, width), 14)
    add(self:recentAnnotationsRow(data, width), 14)
    add(self:recentlyOpenedRow(data, width), 14)
    add(self:recentlyAddedRow(data, width), 14)
    add(self:sectionHeader(_("Browse"), width), 6)
    add(self:browseCategories(width))
    return children
end

function Browser:entityButton(item, width)
    local label = item.title or item.name or "(untitled)"
    local summary = item.summary
    if item.book_count then label = label .. T(_(" · %1 books"), item.book_count) end
    if item.visibility then summary = (summary and (summary .. " · ") or "") .. item.visibility end
    return makeButton(label .. (summary and ("\n" .. summary) or ""), function() self:openItem(item) end,
        width, 56, { size = 16, align = "left", padding = 6, bold = false })
end

function Browser:visibleItems(state)
    return Catalog.visiblePage(state.items or {}, state.page or 1,
        self.layout.page_size, state.local_paged)
end

function Browser:renderEntityList(state)
    local width = Screen:getWidth() - 2 * self.layout.margin
    local total = tonumber(state.total) or #(state.items or {})
    local sort_label = state.sort_label or _("Title (A–Z)")
    local entity_label = ({
        libraries = _("libraries"),
        series = _("series"),
        authors = _("authors"),
        reading_lists = _("reading lists"),
        smart_lists = _("smart lists"),
        library_series = _("series"),
    })[state.kind] or _("items")
    local label = Catalog.pageLabel(total, entity_label, sort_label)
    local header = self:header(state.title, false, label)
    local items = self:visibleItems(state)
    local body = {}
    if #items == 0 then
        body[1] = singleLine(_("No items found."), width, 18, false)
    elseif self.list_mode or not self:itemsHaveCovers(items) then
        for _unused, item in ipairs(items) do body[#body + 1] = self:entityButton(item, width) end
    else
        body = self:gridRows(items, function(item) self:openItem(item) end)
    end
    self:renderPagedScreen(header, VerticalGroup:new(body),
        self:pagingControls(state, width, { list_toggle = true }), width)
end

function Browser:itemsHaveCovers(items)
    for _unused, item in ipairs(items) do
        if item.cover_kind and item.id then return true end
    end
    return false
end

-- One row of covers (at most one grid row) under a section header; used by
-- the book page for "More in series" and "More by author".
function Browser:miniCoverRow(items, title, width)
    local visible = {}
    for index = 1, math.min(#items, self.layout.columns) do visible[index] = items[index] end
    local children = { self:sectionHeader(title, width), VerticalSpan:new{ width = 6 } }
    local rows = self:gridRows(visible, function(item) self:openItem(item) end,
        nil, { show_progress = false, width = width })
    for _unused, row in ipairs(rows) do children[#children + 1] = row end
    children.align = "left"
    return VerticalGroup:new(children)
end

function Browser:gridRows(items, on_select, on_hold, tile_options)
    local rows = {}
    local columns = self.layout.columns
    -- `tile_options.width` fits the grid into a narrower column (Home leaves
    -- room for its scroll bar); tiles shrink and keep their cover ratio.
    local tile_width = self.layout.tile_width
    local cover_height = tile_options and tile_options.cover_height or self.layout.cover_height
    local fit = tile_options and tile_options.width
    if fit then
        local fitted = math.floor((fit - self.layout.gap * (columns - 1)) / columns)
        if fitted < tile_width then
            cover_height = math.floor(cover_height * fitted / tile_width)
            tile_width = fitted
        end
    end
    local scale = tile_options and tile_options.cover_scale
    if scale and scale < 1 then cover_height = math.max(1, math.floor(cover_height * scale)) end
    local index = 1
    while index <= #items do
        local cells = {}
        for _unused = 1, columns do
            local item = items[index]
            if item then
                cells[#cells + 1] = self:coverTile(item, tile_width,
                    cover_height, on_select, tile_options, on_hold)
                index = index + 1
            end
        end
        rows[#rows + 1] = spacedRow(cells, self.layout.gap)
        if index <= #items then rows[#rows + 1] = VerticalSpan:new{ width = self.layout.gap } end
    end
    return rows
end

function Browser:renderBookList(state)
    local width = Screen:getWidth() - 2 * self.layout.margin
    local total = tonumber(state.total) or #(state.items or {})
    local sort_label = state.sort_label or _("Title (A–Z)")
    local label = Catalog.pageLabel(total, _("books"), sort_label)
    local header = self:header(state.title, false, label)
    local footer = self:pagingControls(state, width, { list_toggle = true, audio_toggle = true })
    local items = self:visibleItems(state)
    if not self:showAudio() then
        local kept = {}
        for _unused, item in ipairs(items) do
            if not item.is_audiobook then kept[#kept + 1] = item end
        end
        items = kept
    end
    local body = { align = "left" }
    if #items == 0 then
        body[1] = singleLine(_("No books found."), width, 18, false)
    elseif self.list_mode then
        for _unused, item in ipairs(items) do
            local label_text = item.title or "(untitled)"
            if item.authors then label_text = label_text .. " · " .. item.authors end
            local progress = self:bookProgressText(item)
            if progress ~= "" then label_text = label_text .. " · " .. progress end
            body[#body + 1] = makeButton(label_text, function() self:openItem(item) end,
                width, Screen:scaleBySize(48), { size = 16, align = "left", padding = 5, bold = false })
        end
    else
        -- Fill the space between the bars exactly: rows share the height.
        local rows = self.layout.rows
        local fitted = math.floor((self:pagedBodyHeight(header, footer) + self.layout.gap) / rows
            - self.layout.gap)
        local cover_height = math.max(1, math.min(fitted, math.floor(self.layout.tile_width * 1.7)))
        body = self:gridRows(items, function(item) self:openItem(item) end, nil,
            { cover_height = cover_height })
        body.align = "left"
    end
    self:renderPagedScreen(header, VerticalGroup:new(body), footer, width)
end

-- Height left for a paged screen's body between its top and bottom bars.
function Browser:pagedBodyHeight(header, footer)
    return math.max(1, Screen:getHeight() - 2 * self.layout.margin - header:getSize().h
        - Screen:scaleBySize(6) - Screen:scaleBySize(8) - footer:getSize().h)
end

-- Title bar, then the body, then the bottom bar (page controls and any view
-- toggles). A body that fits needs no scrolling; spare space goes below it.
function Browser:renderPagedScreen(header, body, footer, width)
    local body_height = self:pagedBodyHeight(header, footer)
    local body_content_height = body:getSize().h
    if body_content_height < body_height then
        body = VerticalGroup:new{
            body,
            VerticalSpan:new{ width = body_height - body_content_height },
        }
    end
    self:setContent(VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        ScrollableContainer:new{
            dimen = Geom:new{ w = width, h = body_height },
            show_parent = self,
            body,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        footer,
    })
end

-- Whether audiobooks are listed (Home's Continue reading and book grids share
-- one choice).
function Browser:showAudio()
    return G_reader_settings:nilOrTrue("coppice_show_audio")
end

-- The bottom bar: optional view toggles at the ends, page controls between.
--   [List]  «  ‹   Page 1 of 3   ›  »  [🎧]
function Browser:pagingControls(state, width, opts)
    opts = opts or {}
    local page = tonumber(state.page) or 1
    local pages = math.max(1, tonumber(state.page_count) or 1)
    local button_height = Screen:scaleBySize(48)
    local button_width = Screen:scaleBySize(48)
    local gap = Screen:scaleBySize(2)
    local left, right
    if opts.list_toggle then
        left = makeButton(self.list_mode and _("Covers") or _("List"),
            function() self:toggleListMode() end, Screen:scaleBySize(64), button_height,
            { size = 14, bordersize = 0 })
    end
    if opts.audio_toggle then
        right = self:audioToggle(self:showAudio(), function()
            state.page = 1
            self:loadCurrentScreen()
        end)
    end
    local side = math.max(left and left:getSize().w or 0, right and right:getSize().w or 0)
    local page_width = math.max(1, width - 4 * button_width - 2 * side - 8 * gap)
    local row = {
        makeButton("«", function() self:goToPage(1) end, button_width, button_height, { size = 24, bordersize = 0 }),
        makeButton("‹", function() self:changePage(-1) end, button_width, button_height, { size = 24, bordersize = 0 }),
        CenterContainer:new{
            dimen = Geom:new{ w = page_width, h = button_height },
            -- Narrow bars (a phone with both toggles) use the short form.
            singleLine(page_width >= Screen:scaleBySize(110)
                and T(_("Page %1 of %2"), page, pages) or T(_("%1 / %2"), page, pages),
                page_width, 15, false),
        },
        makeButton("›", function() self:changePage(1) end, button_width, button_height, { size = 24, bordersize = 0 }),
        makeButton("»", function() self:goToPage(pages) end, button_width, button_height, { size = 24, bordersize = 0 }),
    }
    local function slot(widget)
        return CenterContainer:new{ dimen = Geom:new{ w = side, h = button_height },
            widget or HorizontalSpan:new{ width = 0 } }
    end
    if side > 0 then
        table.insert(row, 1, slot(left))
        row[#row + 1] = slot(right)
    end
    return spacedRow(row, gap)
end


function Browser:renderReadingListDetail(state)
    local item = state.item or {}
    self:renderMessage(state.title, T(_([[%1

This server's read-only GraphQL API exposes reading-list names and descriptions, but not the books in a list.]]),
        item.description or item.title or ""))
end

function Browser:renderMessage(title, message)
    local width = Screen:getWidth() - 2 * self.layout.margin
    self:setContent(VerticalGroup:new{
        self:header(title or _("Coppice"), false),
        VerticalSpan:new{ width = 20 },
        textWidget(message, width, 240, 18, "left", false),
    })
end

function Browser:renderError(title, err, code)
    local detail = Errors.describe(err, code)
    self:renderMessage(title, T(_("Could not load this Coppice view.\n%1"), detail))
end

function Browser:renderDetail(state)
    local book = state.book or {}
    book.kind = "book"
    book.cover_kind = "media"
    local width = Screen:getWidth() - 2 * self.layout.margin
    local cover_width = math.floor(width * 0.38)
    local cover_height = math.min(340, math.floor(cover_width * 1.34))
    local title = textWidget(book.title or "(untitled)", width - cover_width - 14, 76, 23, "left", true)
    local authors = book.authors and textWidget(book.authors, width - cover_width - 14, 48, 17, "left", false)
        or singleLine(_("Unknown author"), width - cover_width - 14, 16, false)
    local metadata = {}
    if book.year then metadata[#metadata + 1] = tostring(book.year) end
    if book.publisher then metadata[#metadata + 1] = book.publisher end
    if book.pages then metadata[#metadata + 1] = T(_("%1 pages"), book.pages) end
    if book.extension then metadata[#metadata + 1] = string.upper(book.extension) end
    local details = table.concat(metadata, " · ")
    local progress = self:bookProgressText(book)
    local detail_children = {
        align = "left",
        title,
        VerticalSpan:new{ width = 5 },
        authors,
        VerticalSpan:new{ width = 6 },
        textWidget(details, width - cover_width - 14, 54, 15, "left", false),
    }
    if progress ~= "" then
        detail_children[#detail_children + 1] = VerticalSpan:new{ width = 6 }
        detail_children[#detail_children + 1] = singleLine(progress, width - cover_width - 14, 16, true)
        if book.progression then
            detail_children[#detail_children + 1] = ProgressWidget:new{
                width = width - cover_width - 14, height = 10,
                percentage = Catalog.progressPercent(book.progression) / 100,
                margin_h = 0, margin_v = 0, radius = 0,
            }
        end
    end
    local cover = self:coverWidget(book, cover_width - 8, cover_height)
    local book_head = spacedRow({
        FrameContainer:new{ padding = 4, bordersize = 1, background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{ dimen = Geom:new{ w = cover_width, h = cover_height }, cover } },
        HorizontalSpan:new{ width = 10 },
        VerticalGroup:new(detail_children),
    }, 0)
    local children = {
        self:header(book.title or state.title, false),
        VerticalSpan:new{ width = 12 },
        book_head,
        VerticalSpan:new{ width = 10 },
    }
    if book.tags and #book.tags > 0 then
        children[#children + 1] = textWidget(T(_("Tags: %1"), table.concat(book.tags, ", ")), width, 44, 16, "left", false)
    end
    if book.summary and book.summary ~= "" then
        children[#children + 1] = textWidget(book.summary, width, 174, 16, "left", false)
    end
    if state.detail_error then
        children[#children + 1] = singleLine(_("Some book details could not be loaded."), width, 14, false)
    end
    local action_text
    if book.local_path and lfs.attributes(book.local_path, "mode") == "file" then
        action_text = _("Open")
    elseif book.extension then
        action_text = T(_("Download (%1)"), string.upper(book.extension))
    end
    if book.is_audiobook then
        local edition = book.readable_edition
        if edition then
            children[#children + 1] = textWidget(
                _("This is an audiobook. KOReader can't play audio, but the ebook edition is available."),
                width, 48, 15, "left", false)
            children[#children + 1] = makeButton(
                T(_("Read the ebook (%1)"), string.upper(edition.extension)),
                function() self:openItem(edition) end, width, 48, { size = 18 })
        else
            children[#children + 1] = textWidget(
                _("This is an audiobook. KOReader can't play audio; listen in Coppice Home or an audiobook app."),
                width, 48, 15, "left", false)
        end
    elseif action_text then
        children[#children + 1] = makeButton(action_text, function()
            if book.local_path and lfs.attributes(book.local_path, "mode") == "file" then
                self.on_download_complete(book.local_path, book)
            else
                self:downloadAndOpen(book)
            end
        end, width, 48, { size = 18 })
    else
        children[#children + 1] = singleLine(_("No downloadable KOReader format is available."), width, 15, false)
    end
    if self.on_remote_notes then
        children[#children + 1] = makeButton(_("Remote notes"), function()
            self.on_remote_notes(book)
        end, width, 48, { size = 17 })
    end
    if book.related_series and #book.related_series > 0 then
        children[#children + 1] = VerticalSpan:new{ width = 12 }
        children[#children + 1] = self:miniCoverRow(book.related_series, T(_("More in %1"), book.series or _("series")), width, "recent")
    end
    if book.related_author and #book.related_author > 0 then
        children[#children + 1] = VerticalSpan:new{ width = 12 }
        children[#children + 1] = self:miniCoverRow(book.related_author, T(_("More by %1"), book.authors or _("author")), width, "recent")
    end
    children.align = "left"
    self:setContent(VerticalGroup:new(children))
end

function Browser:downloadAndOpen(book)
    if not book.id then return self:showFailure(_("This entry has no Coppice book id.")) end
    if not book.extension then return self:showFailure(_("This book's format cannot be downloaded by KOReader.")) end
    local dir = self.download_dir
    if not dir or dir == "" then return self:showFailure(_("Choose a download folder in the Coppice menu first.")) end
    if lfs.attributes(dir, "mode") ~= "directory" and not util.makePath(dir) then
        return self:showFailure(_("Could not create the download folder."))
    end
    local filename = (book.title or "book"):gsub("[/\\:%*%?\"<>|]", "_")
        :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if filename == "" then filename = "book" end
    if #filename > 96 then filename = filename:sub(1, 96) end
    local path = dir .. "/" .. filename .. "-" .. tostring(book.id):sub(1, 8) .. "." .. book.extension
    local function start()
        UIManager:show(InfoMessage:new{ text = _("Downloading…"), timeout = 1 })
        UIManager:scheduleIn(0.1, function()
            local saved, err, code = self.api:downloadBook(book.id, path)
            if not saved then return self:showFailure(Errors.describe(err, code)) end
            if self.on_download_complete then self.on_download_complete(saved, book) end
        end)
    end
    if lfs.attributes(path) then
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 already exists."), path),
            ok_text = _("Overwrite"),
            ok_callback = start,
            other_buttons = {{{
                text = _("Open existing"),
                callback = function()
                    if self.on_download_complete then self.on_download_complete(path, book) end
                end,
            }}},
        })
    else
        start()
    end
end

function Browser:showFailure(message)
    UIManager:show(InfoMessage:new{ text = message, icon = "notice-warning" })
end

-- The desktop window can be resized; re-lay out the current screen for the
-- new size. Home re-renders from its data; other screens reload.
function Browser:onScreenResize()
    self.layout = Catalog.layout(Screen:getWidth(), Screen:getHeight(), Screen:scaleBySize(1000) / 1000)
    local state = self.screen_state or {}
    if state.kind == "home" and state.data then
        self:renderHome(state.data)
    else
        self:loadCurrentScreen()
    end
end

function Browser:setContent(widget)
    if self[1] and self[1].free then self[1]:free() end
    self[1] = FrameContainer:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        margin = 0,
        padding = self.layout.margin,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        widget,
    }
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    UIManager:setDirty(self, "full")
end

return Browser
