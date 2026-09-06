--[[--
Stump — a first-party KOReader plugin for a self-hosted Stump server.

What it does, and which Stump surface each part uses:

| Feature                      | Surface                                        |
| ---------------------------- | ---------------------------------------------- |
| Continue reading (dashboard) | `GET /api/v2/reading/continue`                 |
| Browse libraries/series/books| `GET /opds/v2.0/...` (JSON)                    |
| Download a book              | `GET /api/v2/media/{id}/file`                  |
| Progress, automatic          | KOReader's built-in `kosync`, pointed at Stump |
| Progress, on demand          | `/koreader/{api_key}/syncs/progress` PUT/GET   |
| Highlights and notes         | `POST /v1/annotations` (liseur-sync)           |

There is no plugin-owned progress scheduler: KOReader's `kosync` plugin
already debounces pushes on page turn, suspend and close, and Stump
implements exactly the routes it calls, so this plugin *configures* that
client instead of duplicating it. The on-demand push/pull below exists only so
a menu action can report a result.

Book identity is the one place Stump and KOReader do not already agree, and
this plugin resolves it in three steps, most reliable first:

1. a book downloaded through this plugin records its Stump media id in the
   document's sidecar;
2. otherwise the dashboard's `koreaderHash` is matched against the sidecar's
   `partial_md5_checksum` — the same partial MD5 Stump stores as
   `media.koreader_hash`, so any book that has ever synced progress is
   identifiable;
3. otherwise the user links it by hand from a search.

Nothing is guessed from a title.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local md5 = require("ffi/sha2").md5
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Annotations = require("stump_annotations")
local Api = require("stump_api")
local Browser = require("stump_browser")
local KoSync = require("stump_kosync")
local Opds = require("stump_opds")
local Url = require("stump_url")

local Stump = WidgetContainer:extend{
    name = "stump",
    settings_file = DataStorage:getSettingsDir() .. "/stump.lua",
    settings = nil,
    updated = nil,
}

local DEFAULT_SETTINGS = {
    server = nil,
    username = nil,
    password = nil,
    api_key = nil,
    download_dir = nil,
    liseur_secret = nil,
}

function Stump:init()
    self:loadSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Stump:loadSettings()
    if self.settings then return end
    if not Stump.settings_obj then
        Stump.settings_obj = LuaSettings:open(self.settings_file)
    end
    self.settings = Stump.settings_obj:readSetting("settings", DEFAULT_SETTINGS)
end

function Stump:saveSettings()
    Stump.settings_obj:saveSetting("settings", self.settings)
    Stump.settings_obj:flush()
    self.updated = nil
    self.api = nil
end

function Stump:onFlushSettings()
    if self.updated then self:saveSettings() end
end

function Stump:onDispatcherRegisterActions()
    Dispatcher:registerAction("stump_browse",
        { category = "none", event = "ShowStumpBrowser",
          title = _("Stump: browse library"), general = true })
    Dispatcher:registerAction("stump_push_progress",
        { category = "none", event = "StumpPushProgress",
          title = _("Stump: push reading progress"), reader = true })
    Dispatcher:registerAction("stump_export_annotations",
        { category = "none", event = "StumpExportAnnotations",
          title = _("Stump: export highlights"), reader = true })
end

-- ----------------------------------------------------------------- client

function Stump:client()
    if self.api then return self.api end
    local base = Url.normalizeBase(self.settings.server)
    if not base then return nil end
    self.api = Api.new{
        base = base,
        username = self.settings.username,
        password = self.settings.password,
        api_key = self.settings.api_key,
        device_id = G_reader_settings:readSetting("device_id"),
        device_name = Device.model,
        liseur_secret = self.settings.liseur_secret,
    }
    return self.api
end

local function warn(message, detail)
    UIManager:show(InfoMessage:new{
        text = detail and T("%1\n%2", message, tostring(detail)) or message,
        icon = "notice-warning",
    })
end

local function inform(message)
    UIManager:show(InfoMessage:new{ text = message })
end

function Stump:requireClient()
    local api = self:client()
    if not api then
        warn(_("Set your Stump server address first."))
        return nil
    end
    if not api:isConfigured() then
        warn(_("Set a username plus either a password or an API key."))
        return nil
    end
    return api
end

-- ------------------------------------------------------------------- menu

function Stump:addToMainMenu(menu_items)
    menu_items.stump = {
        text = _("Stump"),
        sorting_hint = "tools",
        sub_item_table = self:menuTable(),
    }
end

function Stump:menuTable()
    local items = {
        {
            text = _("Browse library"),
            keep_menu_open = false,
            callback = function() self:onShowStumpBrowser() end,
        },
        {
            text_func = function()
                local base = Url.normalizeBase(self.settings.server)
                return base and T(_("Server: %1"), base) or _("Server: not set")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showServerDialog(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                if (self.settings.username or "") == "" then
                    return _("Account: not set")
                end
                local credential = (self.settings.api_key or "") ~= ""
                    and _("API key") or _("password")
                return T(_("Account: %1 (%2)"), self.settings.username, credential)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showAccountDialog(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                return T(_("Download folder: %1"), self:downloadDir())
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:chooseDownloadDir(touchmenu_instance)
            end,
            separator = true,
        },
        {
            text_func = function()
                local base = Url.normalizeBase(self.settings.server)
                if base and self.settings.api_key
                        and KoSync.isConfiguredFor(base, self.settings.api_key) then
                    return _("Automatic progress sync: configured")
                end
                return _("Set up automatic progress sync")
            end,
            help_text = _([[
Points KOReader's built-in Progress sync plugin at this Stump server: sets the custom sync server to /koreader/<your API key>, fills in the username and key fields it requires (Stump ignores them), and switches document matching to Binary, which is the only method Stump supports.

Requires an API key. Restart KOReader afterwards so the built-in plugin re-reads its settings.]]),
            enabled_func = function()
                return (self.settings.api_key or "") ~= ""
                    and Url.normalizeBase(self.settings.server) ~= nil
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:configureKosync(touchmenu_instance)
            end,
        },
        {
            text = _("Check server connection"),
            keep_menu_open = true,
            callback = function() self:checkConnection() end,
            separator = true,
        },
    }

    if self.ui.document then
        table.insert(items, {
            text = _("Push this book's progress now"),
            keep_menu_open = true,
            callback = function() self:onStumpPushProgress() end,
        })
        table.insert(items, {
            text = _("Pull this book's progress from Stump"),
            keep_menu_open = true,
            callback = function() self:pullProgress() end,
        })
        table.insert(items, {
            text = _("Export highlights and notes to Stump"),
            keep_menu_open = true,
            callback = function() self:onStumpExportAnnotations() end,
        })
        table.insert(items, {
            text_func = function()
                local id = self:linkedBookId()
                return id and T(_("Linked book: %1"), id:sub(1, 8))
                    or _("Link this book to a Stump book…")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showLinkDialog(touchmenu_instance)
            end,
        })
    end

    return items
end

-- --------------------------------------------------------------- settings

function Stump:downloadDir()
    if (self.settings.download_dir or "") ~= "" then
        return self.settings.download_dir
    end
    return G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("lastdir")
        or DataStorage:getFullDataDir()
end

function Stump:showServerDialog(touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Stump server address"),
        input = self.settings.server or "http://",
        input_hint = "http://192.168.1.10:10801",
        description = _([[
The server root, for example http://192.168.1.10:10801. A pasted OPDS, /api/v2 or /koreader/<key> URL is trimmed back to the root automatically.]]),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                local base = Url.normalizeBase(value)
                if not base then
                    return warn(_("That is not an http:// or https:// address."))
                end
                UIManager:close(dialog)
                self.settings.server = base
                -- A different server means a different account, so the
                -- annotation device secret it minted is worthless.
                self.settings.liseur_secret = nil
                self:saveSettings()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Stump:showAccountDialog(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Stump account"),
        fields = {
            { description = _("Username"), text = self.settings.username or "" },
            { description = _("Password (needed for highlight export)"),
              text = self.settings.password or "", text_type = "password" },
            { description = _("API key (needed for progress sync)"),
              text = self.settings.api_key or "" },
        },
        description = _([[
The API key is the narrower credential and is what progress sync needs: Stump authenticates KOSync by the key in the URL. The password is only needed for highlight export, which mints its own device token from a login.]]),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local fields = dialog:getFields()
                UIManager:close(dialog)
                local function blank_to_nil(value)
                    if type(value) ~= "string" or value == "" then return nil end
                    return value
                end
                self.settings.username = blank_to_nil(fields[1])
                self.settings.password = blank_to_nil(fields[2])
                local new_key = blank_to_nil(fields[3])
                if new_key ~= self.settings.api_key then
                    self.settings.api_key = new_key
                end
                self.settings.liseur_secret = nil
                self:saveSettings()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Stump:chooseDownloadDir(touchmenu_instance)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        select_file = false,
        path = self:downloadDir(),
        onConfirm = function(path)
            self.settings.download_dir = path
            self:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    })
end

-- ------------------------------------------------------------------ actions

function Stump:onShowStumpBrowser()
    local api = self:requireClient()
    if not api then return true end

    self.browser = Browser:new{
        api = api,
        download_dir = self:downloadDir(),
        title = _("Stump"),
        title_bar_fm_style = true,
        on_download_complete = function(path, book)
            self:rememberDownload(path, book)
            self:openDownloadedFile(path)
        end,
        close_callback = function()
            UIManager:close(self.browser)
            self.browser = nil
        end,
    }
    UIManager:show(self.browser)
    return true
end

--- Closes the browser and opens the file.
---
--- Which call opens it depends on where the browser was opened from: from the
--- reader the document has to be *switched*, from the file browser it is
--- simply opened. Getting this wrong leaves two documents live.
function Stump:openDownloadedFile(file)
    if self.browser then self.browser.close_callback() end
    if self.ui.document then
        self.ui:switchDocument(file)
    else
        self.ui:openFile(file)
    end
end

function Stump:checkConnection()
    local api = self:requireClient()
    if not api then return end
    NetworkMgr:runWhenConnected(function()
        local lines = {}

        local catalog, err, code = api:opdsCatalog()
        table.insert(lines, catalog and _("OPDS 2.0: OK")
            or T(_("OPDS 2.0: %1"), tostring(code or err)))

        local items, api_err, api_code = api:continueReading(1)
        if items then
            table.insert(lines, T(_("Reading list: OK (%1 in progress)"), #items))
        else
            table.insert(lines, T(_("Reading list: %1"), tostring(api_code or api_err)))
        end

        if (self.settings.api_key or "") ~= "" then
            local auth, ko_err, ko_code = api:kosyncAuth()
            table.insert(lines, auth and _("Progress sync: OK")
                or T(_("Progress sync: %1"), tostring(ko_code or ko_err)))
        else
            table.insert(lines, _("Progress sync: no API key set"))
        end

        if (self.settings.password or "") ~= "" then
            local token = api:liseurLogin()
            table.insert(lines, token and _("Highlight export: OK")
                or _("Highlight export: login failed"))
        else
            table.insert(lines, _("Highlight export: no password set"))
        end

        inform(table.concat(lines, "\n"))
    end)
end

function Stump:configureKosync(touchmenu_instance)
    local base = Url.normalizeBase(self.settings.server)
    if not base or (self.settings.api_key or "") == "" then
        return warn(_("A server address and an API key are required."))
    end
    NetworkMgr:runWhenConnected(function()
        local api = self:requireClient()
        if not api then return end
        local ok, err, code = api:kosyncAuth()
        if not ok then
            return warn(_("Stump rejected that API key for progress sync."),
                code or err)
        end
        local patch, patch_err =
            KoSync.configure(base, self.settings.api_key, self.settings.username)
        if not patch then
            return warn(_("Could not write the progress sync settings."), patch_err)
        end
        if touchmenu_instance then touchmenu_instance:updateItems() end
        inform(T(_([[
Progress sync now points at:

%1

Document matching is set to Binary. Restart KOReader so its Progress sync plugin picks this up.]]), patch.custom_server))
    end)
end

-- ------------------------------------------------------- book <-> media id

--- The Stump media id for the open document, if known.
function Stump:linkedBookId()
    if not self.ui or not self.ui.doc_settings then return nil end
    local id = self.ui.doc_settings:readSetting("stump_media_id")
    if type(id) ~= "string" or id == "" then return nil end
    return id
end

function Stump:setLinkedBookId(id)
    if not self.ui or not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("stump_media_id", id)
    self.ui.doc_settings:flush()
end

--- Records the media id on a freshly downloaded file's sidecar.
---
--- The sidecar is written before the book is opened, so the link exists the
--- first time the reader asks for it.
function Stump:rememberDownload(path, book)
    if not book or not book.id then return end
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(path)
    doc_settings:saveSetting("stump_media_id", book.id)
    doc_settings:flush()
    logger.dbg("Stump: linked", path, "to media", book.id)
end

--- Resolves the open document to a Stump media id.
---
--- Step 2 of the identity ladder: the dashboard hands back
--- `media.koreader_hash` for every book in progress, and the sidecar holds the
--- same partial MD5, so an exact string match identifies the book with no
--- guessing. Only books with a reading head are covered, which is exactly the
--- set that has ever synced progress.
function Stump:resolveBookIdByHash(api)
    local hash = KoSync.documentHash(self.ui and self.ui.doc_settings)
    if not hash then return nil, "no_partial_md5" end
    local items, err, code = api:continueReading(50)
    if not items then return nil, code or err end
    for _, item in ipairs(items) do
        if item.koreaderHash == hash then
            self:setLinkedBookId(item.mediaId)
            return item.mediaId
        end
    end
    return nil, "not_in_reading_list"
end

function Stump:bookId(api)
    return self:linkedBookId() or self:resolveBookIdByHash(api)
end

function Stump:showLinkDialog(touchmenu_instance)
    local api = self:requireClient()
    if not api then return end
    local dialog
    local title = self.ui and self.ui.doc_props and self.ui.doc_props.display_title
    dialog = InputDialog:new{
        title = _("Find this book on Stump"),
        input = title or "",
        input_hint = _("title or author"),
        description = _([[
Searches your Stump library and links the open document to the book you pick, so progress and highlights land on the right record.]]),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = dialog:getInputText()
                UIManager:close(dialog)
                if not query or query == "" then return end
                NetworkMgr:runWhenConnected(function()
                    self:pickSearchResult(api, query, touchmenu_instance)
                end)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Stump:pickSearchResult(api, query, touchmenu_instance)
    local feed, err, code = api:opdsSearch(query, 1, 20)
    if not feed then
        return warn(_("Search failed."), code or err)
    end
    local candidates = {}
    for _, group in ipairs(Opds.groups(api.base, feed)) do
        for _, pub in ipairs(group.publications) do
            if pub.id then table.insert(candidates, pub) end
        end
    end
    for _, pub in ipairs(Opds.publications(api.base, feed)) do
        if pub.id then table.insert(candidates, pub) end
    end
    if #candidates == 0 then
        return warn(_("No matching books on the server."))
    end

    local Menu = require("ui/widget/menu")
    local rows, picker = {}, nil
    for _, pub in ipairs(candidates) do
        local label = pub.title
        if pub.series and pub.series ~= pub.title then
            label = pub.series .. " — " .. label
        end
        table.insert(rows, {
            text = label,
            callback = function()
                UIManager:close(picker)
                self:setLinkedBookId(pub.id)
                if touchmenu_instance then touchmenu_instance:updateItems() end
                inform(T(_("Linked to %1."), pub.title))
            end,
        })
    end
    picker = Menu:new{
        title = _("Pick the matching book"),
        item_table = rows,
        is_popout = false,
        is_borderless = true,
        onMenuSelect = function(_menu, item)
            item.callback()
            return true
        end,
        close_callback = function() UIManager:close(picker) end,
    }
    UIManager:show(picker)
end

-- --------------------------------------------------------------- progress

--- The progress string and percentage KOReader would push itself.
---
--- A paged document reports a page number, a reflowable one a crengine DOM
--- x-pointer. Stump stores a numeric value as a page and keeps a non-numeric
--- one verbatim as `koreader_progress`; it never converts between them.
function Stump:currentProgress()
    if not self.ui or not self.ui.document then return nil end
    local Math = require("optmath")
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress(),
            Math.roundPercent(self.ui.paging:getLastPercent())
    end
    return self.ui.rolling:getLastProgress(),
        Math.roundPercent(self.ui.rolling:getLastPercent())
end

function Stump:onStumpPushProgress()
    local api = self:requireClient()
    if not api then return true end
    if (self.settings.api_key or "") == "" then
        warn(_("Progress sync needs an API key."))
        return true
    end
    local hash = KoSync.documentHash(self.ui and self.ui.doc_settings)
    if not hash then
        warn(_("This book has no partial MD5 yet — open it once and try again."))
        return true
    end
    local progress, percentage = self:currentProgress()
    if progress == nil then
        warn(_("No reading position to push."))
        return true
    end
    NetworkMgr:runWhenConnected(function()
        local body, err, code = api:kosyncPush(hash, progress, percentage)
        if not body then
            if code == 404 then
                return warn(_([[
Stump does not know this file.

Its partial MD5 is not in your library: either the book was not scanned with hashing enabled, or this file is not the copy Stump has.]]))
            end
            return warn(_("Push failed."), code or err)
        end
        inform(T(_("Pushed %1%% to Stump."),
            math.floor((percentage or 0) * 100 + 0.5)))
    end)
    return true
end

function Stump:pullProgress()
    local api = self:requireClient()
    if not api then return end
    if (self.settings.api_key or "") == "" then
        return warn(_("Progress sync needs an API key."))
    end
    local hash = KoSync.documentHash(self.ui and self.ui.doc_settings)
    if not hash then
        return warn(_("This book has no partial MD5 yet."))
    end
    NetworkMgr:runWhenConnected(function()
        local body, err, code = api:kosyncPull(hash)
        if not body then return warn(_("Pull failed."), code or err) end
        if not body.progress then
            return inform(_("Stump has no saved position for this book."))
        end
        local percentage = tonumber(body.percentage) or 0
        UIManager:show(ConfirmBox:new{
            text = T(_("Stump has this book at %1%% (from %2).\n\nJump there?"),
                math.floor(percentage * 100 + 0.5),
                body.device or _("another device")),
            ok_text = _("Jump"),
            ok_callback = function()
                local Event = require("ui/event")
                if self.ui.document.info.has_pages then
                    self.ui:handleEvent(Event:new("GotoPage",
                        tonumber(body.progress)))
                else
                    self.ui:handleEvent(Event:new("GotoXPointer", body.progress))
                end
            end,
        })
    end)
end

-- ------------------------------------------------------------ annotations

--- Where the plugin remembers each annotation's last accepted server
--- revision, so the next push is a compare-and-set edit instead of a
--- create-that-conflicts.
function Stump:annotationRevisions()
    if not self.ui or not self.ui.doc_settings then return {} end
    return self.ui.doc_settings:readSetting("stump_annotation_revs") or {}
end

function Stump:saveAnnotationRevisions(revisions)
    if not self.ui or not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("stump_annotation_revs", revisions)
    self.ui.doc_settings:flush()
end

function Stump:onStumpExportAnnotations()
    local api = self:requireClient()
    if not api then return true end
    if (self.settings.password or "") == "" then
        warn(_([[
Highlight export needs your Stump password.

The annotation lane mints its own device token from a login, and Stump verifies the real password there — an API key cannot stand in.]]))
        return true
    end

    local items = self.ui and self.ui.annotation and self.ui.annotation.annotations
    if not items or #items == 0 then
        warn(_("This book has no highlights, notes or bookmarks."))
        return true
    end

    NetworkMgr:runWhenConnected(function()
        self:exportAnnotations(api, items)
    end)
    return true
end

function Stump:exportAnnotations(api, items)
    local secret, minted, err = api:liseurEnsureToken()
    if not secret then
        return warn(_("Could not get an annotation token."), err)
    end
    if minted then
        self.settings.liseur_secret = secret
        self:saveSettings()
        -- saveSettings drops the cached client; keep using this one.
        self.api = api
    end

    local book_id, id_err = self:bookId(api)
    if not book_id then
        return warn(_([[
This book is not linked to a Stump book yet.

Use "Link this book to a Stump book…", or push its progress once so Stump can match it by hash.]]), id_err)
    end

    local work_id, resolved = api:liseurResolveWork(secret, book_id)
    if not work_id then
        return warn(_("Stump could not resolve this book's work id."), resolved)
    end

    -- When the server matched an exact-bytes edition it hands the digest back
    -- in `identifiers`; pinning the annotation to it is strictly better
    -- provenance than the work alone. It is often absent (a library whose
    -- files Stump could not read in full), and inventing one would be worse
    -- than omitting it.
    local edition_sha
    for _, identifier in ipairs(resolved and resolved.identifiers or {}) do
        if identifier.kind == "sha256" and type(identifier.value) == "string" then
            edition_sha = identifier.value
        end
    end

    local revisions = self:annotationRevisions()
    local inputs, skipped = Annotations.batch(items, {
        work_id = work_id,
        edition_sha = edition_sha,
        document_hash = KoSync.documentHash(self.ui.doc_settings),
        page_count = self.ui.document and self.ui.document:getPageCount() or nil,
        digest = md5,
        revisions = revisions,
    })

    if #inputs == 0 then
        return warn(_("Nothing exportable in this book's annotations."))
    end

    local applied, duplicate, conflict, invalid = 0, 0, 0, 0
    for _, chunk in ipairs(Annotations.chunk(inputs)) do
        local body, push_err, code = api:liseurPushAnnotations(secret, chunk)
        if not body then
            return warn(_("Push failed after %1 annotations."), code or push_err)
        end
        for _, result in ipairs(body.results or {}) do
            if result.status == "applied" then
                applied = applied + 1
                if result.id and result.rev then
                    revisions[result.id] = result.rev
                end
            elseif result.status == "duplicate" then
                duplicate = duplicate + 1
                if result.id and result.rev then
                    revisions[result.id] = result.rev
                end
            elseif result.status == "conflict" then
                conflict = conflict + 1
                -- `server` is the server's current copy (`AnnotationResult.
                -- server`); recording its revision makes the next push a
                -- compare-and-set edit instead of the same stale create.
                if result.id and result.server and result.server.rev then
                    revisions[result.id] = result.server.rev
                end
            else
                invalid = invalid + 1
                logger.warn("Stump: annotation rejected", result.id,
                    result.reason or result.status)
            end
        end
    end
    self:saveAnnotationRevisions(revisions)

    local lines = { T(_("Sent %1 annotations to Stump."), #inputs) }
    table.insert(lines, T(_("applied %1 · already there %2 · conflict %3 · rejected %4"),
        applied, duplicate, conflict, invalid))
    for reason, count in pairs(skipped) do
        table.insert(lines, T(_("skipped %1: %2"), count, reason))
    end

    -- Read the live set back: the per-item statuses say what the batch did,
    -- this says what the server now holds, which is the thing the user
    -- actually wanted to know.
    local live = api:liseurWorkAnnotations(secret, work_id)
    if live and live.annotations then
        table.insert(lines,
            T(_("Stump now holds %1 for this book."), #live.annotations))
    end

    inform(table.concat(lines, "\n"))
end

return Stump
