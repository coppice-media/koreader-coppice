--[[--
Coppice — a first-party KOReader plugin for a self-hosted Coppice server.

What it does, and which Coppice surface each part uses:

| Feature                      | Surface                                        |
| ---------------------------- | ---------------------------------------------- |
| Continue reading (home)      | `GET /api/v2/reading/continue`             |
| Home, catalog and detail     | Authenticated `POST /api/graphql`           |
| Download a book               | `GET /api/v2/media/{id}/file`                |
| Progress, automatic           | KOReader's built-in `kosync`, pointed at Coppice |
| Progress, on demand           | `/koreader/{api_key}/syncs/progress` PUT/GET |
| Highlights and notes          | liseur-sync annotation routes                |

There is no plugin-owned progress scheduler: KOReader's `kosync` plugin
already debounces pushes on page turn, suspend and close, and Coppice
implements exactly the routes it calls, so this plugin *configures* that
client instead of duplicating it. The on-demand push/pull below exists only so
a menu action can report a result.

Book identity is the one place Coppice and KOReader do not already agree, and
this plugin resolves it in three steps, most reliable first:

1. a book downloaded through this plugin records its Coppice media id in the
   document's sidecar;
2. otherwise the dashboard's `koreaderHash` is matched against the sidecar's
   `partial_md5_checksum` — the same partial MD5 Coppice stores as
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
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local md5 = require("ffi/sha2").md5
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Annotations = require("coppice_annotations")
local AnnotationSync = require("coppice_annotation_sync")
local Catalog = require("coppice_catalog")
local lfs = require("libs/libkoreader-lfs")
local Api = require("coppice_api")
local Browser = require("coppice_browser")
local Errors = require("coppice_errors")
local Settings = require("coppice_settings")
local KoSync = require("coppice_kosync")
local Opds = require("coppice_opds")
local Url = require("coppice_url")
local Pairing = require("coppice_pairing")
local Migration = require("coppice_migration")

local Coppice = WidgetContainer:extend{
    name = "coppice",
    settings_file = DataStorage:getSettingsDir() .. "/coppice.lua",
    settings = nil,
    updated = nil,
}

local DEFAULT_SETTINGS = {
    server = nil,
    username = nil,
    api_key = nil,
    liseur_secret = nil,
    device_id = nil,
    device_name = nil,
    download_dir = nil,
    pairing_id = nil,
    pairing_nonce = nil,
    pairing_code = nil,
    pairing_expires_at = nil,
    pairing_poll_interval = nil,
}

local function pluginRoot()
    local source = debug.getinfo(1, "S").source or ""
    source = source:gsub("^@", "")
    local directory = source:match("^(.*)/[^/]+$")
    return directory and directory:match("^(.*)/[^/]+$")
end

local function optionalConfig()
    local ok, config = pcall(require, "coppice_config")
    return ok and type(config) == "table" and config or {}
end

local function restoreKosync(base, api_key)
    if not api_key then return false end
    local ok, restored = pcall(KoSync.restore, base, api_key)
    if not ok then
        logger.warn("Coppice: could not restore prior KOReader sync settings")
        return false
    end
    return restored == true
end

local function prioritizeCoppiceMenuOrder(is_filemanager)
    local filemanager_order
    for _unused, module_name in ipairs({
        "ui/elements/filemanager_menu_order",
        "ui/elements/reader_menu_order",
    }) do
        local ok, order = pcall(require, module_name)
        if module_name == "ui/elements/filemanager_menu_order" and ok then
            filemanager_order = order
        end
        local tools = ok and type(order) == "table" and order.tools
        if type(tools) == "table" then
            for index = #tools, 1, -1 do
                if tools[index] == "coppice" then table.remove(tools, index) end
            end
            table.insert(tools, 1, "coppice")
        end
    end
    local main = is_filemanager and type(filemanager_order) == "table"
        and filemanager_order.main
    if type(main) == "table" then
        for index = #main, 1, -1 do
            if main[index] == "coppice_browse" then table.remove(main, index) end
        end
        table.insert(main, 1, "coppice_browse")
    end
end

function Coppice:init()
    prioritizeCoppiceMenuOrder(not self.ui.document)
    self:loadSettings()
    if not self._actions_registered then
        self:onDispatcherRegisterActions()
        self._actions_registered = true
    end
    if not self._main_menu_registered then
        self.ui.menu:registerToMainMenu(self)
        self._main_menu_registered = true
    end
    if not self._pairing_bootstrapped then
        self._pairing_bootstrapped = true
        UIManager:scheduleIn(0.1, function() self:maybeStartPairing() end)
    end
    self:maybeOpenOnStart()
end

-- Opens Coppice Home once per KOReader run, from the file browser only, so
-- closing a book still returns to the file browser.
function Coppice:maybeOpenOnStart()
    if Coppice._opened_on_start or self.ui.document then return end
    Coppice._opened_on_start = true
    if not self.settings.open_on_start then return end
    local api = self:client()
    if not (api and api:isConfigured()) then return end
    UIManager:scheduleIn(0.2, function() self:onShowCoppiceBrowser() end)
end

function Coppice:loadSettings()
    if self.settings then return end
    Migration.run(pluginRoot(), DataStorage:getSettingsDir())
    if not Coppice.settings_obj then
        Coppice.settings_obj = LuaSettings:open(self.settings_file)
    end
    local saved = Coppice.settings_obj:readSetting("settings", DEFAULT_SETTINGS)
    self.settings = Settings.validate(saved, optionalConfig())
end
function Coppice:onCoppicePair()
    self:startPairing()
    return true
end


function Coppice:saveSettings()
    self.settings = Settings.validate(self.settings)
    Coppice.settings_obj:saveSetting("settings", self.settings)
    Coppice.settings_obj:flush()
    self.updated = nil
    self.api = nil
end

function Coppice:onFlushSettings()
    if self.updated then self:saveSettings() end
end

function Coppice:onDispatcherRegisterActions()
    Dispatcher:registerAction("coppice_browse",
        { category = "none", event = "ShowCoppiceBrowser",
          title = _("Coppice: browse library"), general = true })
    Dispatcher:registerAction("coppice_pair",
        { category = "none", event = "CoppicePair", title = _("Coppice: pair device"), general = true })
    Dispatcher:registerAction("coppice_push_progress",
        { category = "none", event = "CoppicePushProgress",
          title = _("Coppice: push reading progress"), reader = true })
    Dispatcher:registerAction("coppice_sync_annotations",
        { category = "none", event = "CoppiceSyncAnnotations",
          title = _("Coppice: sync annotations now"), reader = true })
end

-- ----------------------------------------------------------------- client

function Coppice:client()
    if self.api then return self.api end
    local base = Url.normalizeBase(self.settings.server)
    if not base then return nil end
    self.api = Api.new{
        base = base,
        username = self.settings.username or "coppice",
        api_key = self.settings.api_key,
        device_id = self.settings.device_id or G_reader_settings:readSetting("device_id"),
        device_name = self.settings.device_name or Device.model,
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
local function warnApi(message, err, code)
    return warn(message, Errors.describe(err, code))
end

local function inform(message)
    UIManager:show(InfoMessage:new{ text = message })
end

function Coppice:requireClient()
    local api = self:client()
    if not api then
        warn(_("Set your Coppice server address first."))
        return nil
    end
    if not api:isConfigured() then
        warn(_("Pair this device with Coppice before using the library."))
        return nil
    end
    return api
end

-- ------------------------------------------------------------------- menu

function Coppice:addToMainMenu(menu_items)
    menu_items.coppice = {
        text = _("Coppice"),
        sorting_hint = "tools",
        sub_item_table = self:menuTable(),
    }
    if not self.ui.document then
        menu_items.coppice_browse = {
            text = _("Browse Coppice library"),
            sorting_hint = "main",
            callback = function() self:onShowCoppiceBrowser() end,
        }
    end
end

function Coppice:pairingLabel()
    if (self.settings.api_key or "") ~= ""
            and (self.settings.liseur_secret or "") ~= "" then
        return _("Pairing: approved")
    end
    if self.settings.pairing_id and self.settings.pairing_nonce then
        return T(_("Pairing: waiting for approval (%1)"),
            self.settings.pairing_code or "------")
    end
    return _("Pair this device")
end

function Coppice:menuTable()
    local items = {
        {
            text = _("Browse library"),
            keep_menu_open = false,
            callback = function() self:onShowCoppiceBrowser() end,
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
            text_func = function() return self:pairingLabel() end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:startPairing(touchmenu_instance)
            end,
        },
        {
            text = _("Forget this device pairing"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:forgetPairing(touchmenu_instance)
            end,
        },
        {
            text = _("Open Coppice when KOReader starts"),
            checked_func = function() return self.settings.open_on_start end,
            keep_menu_open = true,
            callback = function()
                self.settings.open_on_start = not self.settings.open_on_start
                self:saveSettings()
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
Points KOReader's built-in Progress sync plugin at this Coppice server: sets the custom sync server to /koreader/<your API key>, fills in the approved username and key fields it requires, and switches document matching to Binary, which is the only method Coppice supports.

Requires an approved pairing. Restart KOReader afterwards so the built-in plugin re-reads its settings.]]),
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
            callback = function() self:onCoppicePushProgress() end,
        })
        table.insert(items, {
            text = _("Pull this book's progress from Coppice"),
            keep_menu_open = true,
            callback = function() self:pullProgress() end,
        })
        table.insert(items, {
            text = _("Sync annotations now"),
            keep_menu_open = true,
            callback = function() self:syncAnnotationsNow() end,
        })
        table.insert(items, {
            text = _("Remote notes"),
            keep_menu_open = true,
            callback = function() self:showRemoteNotes() end,
        })
        table.insert(items, {
            text_func = function()
                local id = self:linkedBookId()
                return id and T(_("Linked book: %1"), id:sub(1, 8))
                    or _("Link this book to a Coppice book…")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showLinkDialog(touchmenu_instance)
            end,
        })
    end

    return items
end

-- --------------------------------------------------------------- pairing

function Coppice:clearPairingState()
    self.settings.pairing_id = nil
    self.settings.pairing_nonce = nil
    self.settings.pairing_code = nil
    self.settings.pairing_expires_at = nil
    self.settings.pairing_poll_interval = nil
    self._pairing_poll_scheduled = nil
end

function Coppice:showPairingCode(body)
    local code = Pairing.formatCode(body.code or self.settings.pairing_code)
    local expires = Pairing.expiresIn(
        body.expires_at or self.settings.pairing_expires_at, os.time())
    local server = (self.settings.server or ""):gsub("/+$", "")
    local where = server ~= "" and (server .. "/app/devices") or _("Coppice → Devices")
    local lines = {
        _("Pair with Coppice"),
        "",
        code,
        "",
        T(_("Open %1 and enter this code under Pending pairings."), where),
    }
    if expires then lines[#lines + 1] = T(_("Code %1."), expires) end
    lines[#lines + 1] = _("Don't share this code.")
    inform(table.concat(lines, "\n"))
end

function Coppice:pairingDeviceName()
    return self.settings.device_name or Device.model or "KOReader"
end

function Coppice:maybeStartPairing()
    if (self.settings.api_key or "") ~= ""
            and (self.settings.liseur_secret or "") ~= "" then
        return
    end
    if self.settings.pairing_id and self.settings.pairing_nonce then
        self:showPairingCode({
            code = self.settings.pairing_code,
            expires_at = self.settings.pairing_expires_at,
        })
        self:schedulePairingPoll(0.2)
        return
    end
    if not Url.normalizeBase(self.settings.server) then
        self:showServerDialog(nil, true)
        return
    end
    self:startPairing()
end

function Coppice:startPairing(touchmenu_instance)
    local base = Url.normalizeBase(self.settings.server)
    if not base then
        return self:showServerDialog(touchmenu_instance, true)
    end
    if self.settings.pairing_id and self.settings.pairing_nonce then
        self:showPairingCode({
            code = self.settings.pairing_code,
            expires_at = self.settings.pairing_expires_at,
        })
        self:schedulePairingPoll(0.2)
        return
    end

    local api = self:client()
    if not api then return warn(_("Set your Coppice server address first.")) end
    NetworkMgr:runWhenConnected(function()
        local body, err, code = api:pairingStart(self:pairingDeviceName())
        if not body then
            return warnApi(_("Could not start Coppice pairing."), err, code)
        end
        self.settings.server = base
        self.settings.pairing_id = body.pairing_id
        self.settings.pairing_nonce = body.nonce
        self.settings.pairing_code = body.code
        self.settings.pairing_expires_at = body.expires_at
        self.settings.pairing_poll_interval = Pairing.pollInterval(body, 2)
        self:saveSettings()
        if touchmenu_instance then touchmenu_instance:updateItems() end
        self:showPairingCode(body)
        self:schedulePairingPoll(self.settings.pairing_poll_interval)
    end)
end

function Coppice:schedulePairingPoll(delay)
    if self._pairing_poll_scheduled then return end
    if not self.settings.pairing_id or not self.settings.pairing_nonce then return end
    self._pairing_poll_scheduled = true
    UIManager:scheduleIn(delay or self.settings.pairing_poll_interval or 2, function()
        self._pairing_poll_scheduled = nil
        self:pollPairing()
    end)
end

function Coppice:pollPairing()
    local pairing_id = self.settings.pairing_id
    local nonce = self.settings.pairing_nonce
    if not pairing_id or not nonce then return end
    local api = self:client()
    if not api then return end
    NetworkMgr:runWhenConnected(function()
        local body, err, code = api:pairingStatus(pairing_id, nonce)
        if not body then
            if code == 401 or code == 403 or code == 404 or code == 410 then
                self:clearPairingState()
                self:saveSettings()
                return inform(_("This pairing session is no longer valid. Start pairing again."))
            end
            -- A transient network failure must not discard the nonce. It is
            -- safe to retry; the server still applies its five-minute expiry.
            if not self._pairing_retry_warned then
                warnApi(_("Could not check Coppice pairing status."), err, code)
                self._pairing_retry_warned = true
            end
            self:schedulePairingPoll(self.settings.pairing_poll_interval or 2)
            return
        end
        self._pairing_retry_warned = nil
        if body.status == "pending" then
            self:schedulePairingPoll(Pairing.pollInterval(body,
                self.settings.pairing_poll_interval or 2))
            return
        end
        if body.status == "denied" or body.status == "expired" then
            local message = Pairing.statusMessage(body.status, body.expires_at)
            self:clearPairingState()
            self:saveSettings()
            inform(message)
            return
        end

        local credentials, credential_err = Pairing.credentials(body)
        if not credentials then
            self:clearPairingState()
            self:saveSettings()
            return warn(_("Coppice approval did not include both device credentials."))
        end
        self.settings.username = credentials.username
        self.settings.api_key = credentials.api_key
        self.settings.liseur_secret = credentials.liseur_secret
        self.settings.device_id = credentials.device_id or self.settings.device_id
        self.settings.device_name = credentials.device_name or self.settings.device_name
        self:clearPairingState()
        self:saveSettings()
        local base = Url.normalizeBase(self.settings.server)
        local patch, patch_err = KoSync.configure(base,
            self.settings.api_key, self.settings.username)
        if patch then
            inform(_([[Coppice paired this device and configured automatic progress sync.

Restart KOReader so its Progress sync plugin reloads the settings.]]))
        else
            inform(_("Coppice paired this device, but automatic progress sync could not be configured. Check KOReader's Progress sync settings."))
        end
    end)
end

function Coppice:forgetPairing(touchmenu_instance)
    local dialog
    dialog = ConfirmBox:new{
        text = _([[Forget this device's Coppice credentials?

This removes both local auth lanes and restores prior KOReader sync settings if Coppice still owns them.]]),
        ok_text = _("Forget"),
        ok_callback = function()
            restoreKosync(self.settings.server, self.settings.api_key)
            self.settings.username = nil
            self.settings.api_key = nil
            self.settings.liseur_secret = nil
            self.settings.device_id = nil
            self:clearPairingState()
            self:saveSettings()
            if touchmenu_instance then touchmenu_instance:updateItems() end
            inform(_("Local Coppice credentials removed. Start pairing again when ready."))
        end,
    }
    UIManager:show(dialog)
end

--- Called by an installer/uninstaller integration before removing the folder.
--- It never exports or migrates credentials.
function Coppice:onUninstall()
    restoreKosync(self.settings.server, self.settings.api_key)
    self.settings.username = nil
    self.settings.api_key = nil
    self.settings.liseur_secret = nil
    self.settings.device_id = nil
    self:clearPairingState()
    self:saveSettings()
    pcall(os.remove, self.settings_file)
end

-- --------------------------------------------------------------- settings

function Coppice:downloadDir()
    if (self.settings.download_dir or "") ~= "" then
        return self.settings.download_dir
    end
    return G_reader_settings:readSetting("download_dir")
        or G_reader_settings:readSetting("lastdir")
        or DataStorage:getFullDataDir()
end

function Coppice:showServerDialog(touchmenu_instance, auto_pair)
    local dialog
    dialog = InputDialog:new{
        title = _("Coppice server address"),
        input = self.settings.server or "http://",
        input_hint = "http://192.168.1.10:10801",
        description = _([[
The server root, for example http://192.168.1.10:10801. A pasted OPDS, /api/v2 or /koreader/<key> URL is trimmed back to the root automatically. After saving, Coppice starts a five-minute device pairing window.]]),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Save and pair"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                local base = Url.normalizeBase(value)
                if not base then
                    return warn(_("That is not an http:// or https:// address."))
                end
                UIManager:close(dialog)
                if self.settings.server ~= base then
                    restoreKosync(self.settings.server, self.settings.api_key)
                    self.settings.username = nil
                    self.settings.api_key = nil
                    self.settings.liseur_secret = nil
                    self.settings.device_id = nil
                    self:clearPairingState()
                end
                self.settings.server = base
                self:saveSettings()
                if touchmenu_instance then touchmenu_instance:updateItems() end
                self:startPairing(touchmenu_instance)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Coppice:chooseDownloadDir(touchmenu_instance)
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

function Coppice:onShowCoppiceBrowser()
    local api = self:requireClient()
    if not api then return true end

    self.browser = Browser:new{
        api = api,
        download_dir = self:downloadDir(),
        title = _("Coppice"),
        title_bar_fm_style = true,
        on_download_complete = function(path, book)
            self:rememberDownload(path, book)
            self:openDownloadedFile(path)
        end,
        on_open_file = function(path, book)
            if book and book.id then self:rememberDownload(path, book) end
            return self:openDownloadedFile(path)
        end,
        on_open_annotation = function(item)
            return self:openRecentAnnotation(item)
        end,
        on_recent_annotations = function(titles, cache_only)
            return self:recentAnnotationItems(titles, cache_only)
        end,
        on_pending_count = function()
            return self:pendingSyncCount()
        end,
        on_sync_annotations = self.syncAnnotationsNow and function()
            return self:syncAnnotationsNow()
        end or nil,
        on_remote_notes = function(book)
            return self:showRemoteNotes(book)
        end or nil,
        close_callback = function()
            UIManager:close(self.browser)
            self.browser = nil
        end,
    }
    UIManager:show(self.browser, "full")
    return true
end

--- Closes the browser and opens the file.
---
--- Which call opens it depends on where the browser was opened from: from the
--- reader the document has to be *switched*, from the file browser it is
--- simply opened. Getting this wrong leaves two documents live.
function Coppice:openDownloadedFile(file)
    if self.browser then self.browser.close_callback() end
    if self.ui.document then
        self.ui:switchDocument(file)
    else
        self.ui:openFile(file)
    end
end

function Coppice:localBookPath(item)
    if type(item) ~= "table" then return nil end
    if type(item.local_path) == "string"
            and lfs.attributes(item.local_path, "mode") == "file" then
        return item.local_path
    end
    local book_id = item.book_id or item.media_id
    if not book_id then return nil end
    if self.ui and self.ui.document
            and tostring(self:linkedBookId() or "") == tostring(book_id) then
        return self.ui.document.file
    end
    if self.browser then
        for _unused, local_item in ipairs(self.browser:onDeviceItems()) do
            if tostring(local_item.id) == tostring(book_id)
                    and lfs.attributes(local_item.local_path, "mode") == "file" then
                return local_item.local_path
            end
        end
    end
end

function Coppice:openRecentAnnotation(item)
    local path = self:localBookPath(item)
    if path then
        -- Stored on the class: opening a book creates a new plugin instance
        -- for the reader, which must still see the jump requested here.
        Coppice.pending_annotation_action = {
            kind = (Catalog.isPositionedAnnotation(item) or item.excerpt or item.progression)
                and "jump" or "remote_notes",
            item = item,
            local_path = path,
        }
        if self.ui and self.ui.document and self.ui.document.file == path then
            if self.browser then self.browser:close() end
            self:openPendingAnnotationAction()
            return true
        end
        return self:openDownloadedFile(path)
    end
    local book_id = item and (item.book_id or item.media_id)
    if self.browser and book_id then
        local book = {
            id = tostring(book_id),
            title = item.title or item.book_title or _("Unknown book"),
            kind = "book",
            cover_kind = "media",
        }
        return self.browser:openScreen({
            kind = "detail", title = book.title, book = book,
        })
    end
    inform(_("This annotation is not linked to a Coppice book."))
    return true
end

function Coppice:jumpToRecentAnnotation(item)
    if not self.ui or not self.ui.document or type(item) ~= "table" then
        return false
    end
    if item.document_hash and self.ui.doc_settings then
        local current_hash = KoSync.documentHash(self.ui.doc_settings)
        if current_hash and current_hash ~= item.document_hash then return false end
    end
    local target = item
    local target_id = item.id or item.coppice_id
    for _unused, annotation in ipairs(self.ui.annotation
            and self.ui.annotation.annotations or {}) do
        if target_id and annotation.coppice_id == target_id then
            target = annotation
            break
        end
    end
    local locator = type(target.locator) == "table" and target.locator
        or type(item.locator) == "table" and item.locator or {}
    local position = target.page or target.pos0
        or locator.page or locator.pos0 or target.pageno or locator.pageno
    if type(position) == "table" then position = position.page or target.pageno end
    -- A reflowable book (EPUB) positions by xpointer; a page number from
    -- another app's layout would land somewhere else entirely.
    if self.ui.rolling and type(position) == "number" then position = nil end
    if position == nil then
        -- A note made in another app (Home, Liseur) has no KOReader
        -- position: find its passage in the book, else use its progression.
        local Event = require("ui/event")
        local document = self.ui.document
        local passage = type(item.excerpt) == "string" and item.excerpt:gsub("%s+", " ") or ""
        passage = passage:sub(1, 60):gsub("%s+%S*$", "")
        if self.ui.rolling and #passage >= 8 and type(document.findAllText) == "function" then
            local ok, hits = pcall(document.findAllText, document, passage, true, 0, 1)
            local hit = ok and type(hits) == "table" and hits[1]
            if hit and hit.start then
                self.ui:handleEvent(Event:new("GotoXPointer", hit.start, hit.start))
                return true
            end
        end
        local progression = tonumber(item.progression)
        if progression and progression >= 0 and progression <= 1 then
            self.ui:handleEvent(Event:new("GotoPercent", progression * 100))
            return true
        end
        return false
    end
    local marker = target.pos0 or locator.pos0
    if self.ui.bookmark and type(self.ui.bookmark.gotoBookmark) == "function" then
        self.ui.bookmark:gotoBookmark(position, marker)
    else
        local Event = require("ui/event")
        self.ui:handleEvent(Event:new(
            self.ui.paging and "GotoPage" or "GotoXPointer", position, marker))
    end
    return true
end

function Coppice:openPendingAnnotationAction()
    local action = Coppice.pending_annotation_action
    if not action or not self.ui or not self.ui.document
            or self.ui.document.file ~= action.local_path then
        return
    end
    Coppice.pending_annotation_action = nil
    if action.kind == "jump" and self:jumpToRecentAnnotation(action.item) then return end
    self:showRemoteNotes(action.item)
end

function Coppice:checkConnection()
    local api = self:requireClient()
    if not api then return end
    NetworkMgr:runWhenConnected(function()
        local lines = {}

        local catalog, catalog_err, catalog_code = api:opdsCatalog()
        table.insert(lines, catalog and _("OPDS 2.0: OK")
            or T(_("OPDS 2.0: %1"),
                Errors.describe(catalog_err, catalog_code)))

        local items, api_err, api_code = api:continueReading(1)
        if items then
            table.insert(lines, T(_("Reading list: OK (%1 in progress)"), #items))
        else
            table.insert(lines, T(_("Reading list: %1"),
                Errors.describe(api_err, api_code)))
        end

        if (self.settings.api_key or "") ~= "" then
            local auth, ko_err, ko_code = api:kosyncAuth()
            table.insert(lines, auth and _("Progress sync: OK")
                or T(_("Progress sync: %1"),
                    Errors.describe(ko_err, ko_code)))
        else
            table.insert(lines, _("Progress sync: no API key set"))
        end

        if (self.settings.liseur_secret or "") ~= "" then
            local token, token_err, token_code =
                api:liseurDescribeToken(self.settings.liseur_secret)
            table.insert(lines, token and _("Annotation lane: OK")
                or T(_("Annotation lane: %1"),
                    Errors.describe(token_err, token_code)))
        else
            table.insert(lines, _("Annotation lane: no paired device token"))
        end

        inform(table.concat(lines, "\n"))
    end)
end

function Coppice:configureKosync(touchmenu_instance)
    local base = Url.normalizeBase(self.settings.server)
    if not base or (self.settings.api_key or "") == "" then
        return warn(_("A server address and an API key are required."))
    end
    NetworkMgr:runWhenConnected(function()
        local api = self:requireClient()
        if not api then return end
        local ok, err, code = api:kosyncAuth()
        if not ok then
            return warnApi(_("Coppice rejected that API key for progress sync."),
                err, code)
        end
        local patch, patch_err =
            KoSync.configure(base, self.settings.api_key, self.settings.username)
        if not patch then
            return warn(_("Could not write the progress sync settings."))
        end
        if touchmenu_instance then touchmenu_instance:updateItems() end
        inform(_([[Progress sync was configured to use Coppice.

Document matching is set to Binary. Restart KOReader so its Progress sync plugin picks this up.]]))
    end)
end

-- ------------------------------------------------------- book <-> media id

--- The Coppice media id for the open document, if known.
function Coppice:linkedBookId()
    if not self.ui or not self.ui.doc_settings then return nil end
    local id = self.ui.doc_settings:readSetting("coppice_media_id")
    if type(id) ~= "string" or id == "" then return nil end
    return id
end

function Coppice:setLinkedBookId(id)
    if not self.ui or not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("coppice_media_id", id)
    self.ui.doc_settings:flush()
end

--- Records the media id on a freshly downloaded file's sidecar.
---
--- The sidecar is written before the book is opened, so the link exists the
--- first time the reader asks for it.
function Coppice:rememberDownload(path, book)
    if not book or not book.id then return end
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(path)
    doc_settings:saveSetting("coppice_media_id", book.id)
    doc_settings:flush()
    logger.dbg("Coppice: linked", path, "to media", book.id)
end

--- Resolves the open document to a Coppice media id.
---
--- Step 2 of the identity ladder: the dashboard hands back
--- `media.koreader_hash` for every book in progress, and the sidecar holds the
--- same partial MD5, so an exact string match identifies the book with no
--- guessing. Only books with a reading head are covered, which is exactly the
--- set that has ever synced progress.
function Coppice:resolveBookIdByHash(api)
    local hash = KoSync.documentHash(self.ui and self.ui.doc_settings)
    if not hash then return nil, "no_partial_md5" end
    local items, err, code = api:continueReading(50)
    if not items then return nil, err, code end
    for _unused, item in ipairs(items) do
        if type(item) == "table"
                and item.koreaderHash == hash
                and type(item.mediaId) == "string"
                and item.mediaId ~= "" then
            self:setLinkedBookId(item.mediaId)
            return item.mediaId
        end
    end
    return nil, "not_in_reading_list"
end

function Coppice:bookId(api)
    local linked = self:linkedBookId()
    if linked then return linked end
    return self:resolveBookIdByHash(api)
end

function Coppice:showLinkDialog(touchmenu_instance)
    local api = self:requireClient()
    if not api then return end
    local dialog
    local title = self.ui and self.ui.doc_props and self.ui.doc_props.display_title
    dialog = InputDialog:new{
        title = _("Find this book on Coppice"),
        input = title or "",
        input_hint = _("title or author"),
        description = _([[
Searches your Coppice library and links the open document to the book you pick, so progress and highlights land on the right record.]]),
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

function Coppice:pickSearchResult(api, query, touchmenu_instance)
    local feed, err, code = api:opdsSearch(query, 1, 20)
    if not feed then
        return warnApi(_("Search failed."), err, code)
    end
    local candidates = {}
    for _unused, group in ipairs(Opds.groups(api.base, feed)) do
        for _unused, pub in ipairs(group.publications) do
            if pub.id then table.insert(candidates, pub) end
        end
    end
    for _unused, pub in ipairs(Opds.publications(api.base, feed)) do
        if pub.id then table.insert(candidates, pub) end
    end
    if #candidates == 0 then
        return warn(_("No matching books on the server."))
    end

    local Menu = require("ui/widget/menu")
    local rows, picker = {}, nil
    for _unused, pub in ipairs(candidates) do
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
--- x-pointer. Coppice stores a numeric value as a page and keeps a non-numeric
--- one verbatim as `koreader_progress`; it never converts between them.
function Coppice:currentProgress()
    local document = self.ui and self.ui.document
    local Math = require("optmath")
    if not document or not document.info then return nil end
    local reader = document.info.has_pages and self.ui.paging or self.ui.rolling
    if not reader then return nil end
    local progress = reader:getLastProgress()
    local percentage = reader:getLastPercent()
    if type(percentage) ~= "number" or percentage ~= percentage then
        return progress, nil
    end
    return progress, Math.roundPercent(percentage)
end

function Coppice:onCoppicePushProgress()
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
Coppice does not know this file.

Its partial MD5 is not in your library: either the book was not scanned with hashing enabled, or this file is not the copy Coppice has.]]))
            end
            return warnApi(_("Push failed."), err, code)
        end
        inform(T(_("Pushed %1%% to Coppice."),
            math.floor((percentage or 0) * 100 + 0.5)))
    end)
    return true
end

function Coppice:pullProgress()
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
        if not body then return warnApi(_("Pull failed."), err, code) end
        if not body.progress then
            return inform(_("Coppice has no saved position for this book."))
        end
        local percentage = tonumber(body.percentage) or 0
        if percentage < 0 or percentage > 1 then
            return warn(_("Coppice returned an invalid progress response."))
        end
        local document = self.ui and self.ui.document
        local has_pages = document and document.info and document.info.has_pages
        local target_page = has_pages and tonumber(body.progress) or nil
        if has_pages and not target_page then
            return warn(_("Coppice returned an invalid page position."))
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Coppice has this book at %1%% (from %2).\n\nJump there?"),
                math.floor(percentage * 100 + 0.5),
                body.device or _("another device")),
            ok_text = _("Jump"),
            ok_callback = function()
                local Event = require("ui/event")
                if has_pages then
                    self.ui:handleEvent(Event:new("GotoPage", target_page))
                else
                    self.ui:handleEvent(Event:new("GotoXPointer", body.progress))
                end
            end,
        })
    end)
end

-- ------------------------------------------------------------ annotations
local function mergeAnnotationState(state, saved)
    saved = AnnotationSync.newState(saved)
    for id, revision in pairs(saved.revisions) do
        local current = state.revisions[id]
        local saved_revision = type(revision) == "table"
            and tonumber(revision.rev) or tonumber(revision) or 0
        local current_revision = type(current) == "table"
            and tonumber(current.rev) or tonumber(current) or 0
        if not current or saved_revision >= current_revision then
            state.revisions[id] = AnnotationSync.copy(revision)
        end
    end
    for _unused, key in ipairs({
        "id_map", "managed", "queue", "remote_notes", "tombstones",
    }) do
        for id, value in pairs(saved[key]) do
            if key == "queue" or state[key][id] == nil then
                state[key][id] = AnnotationSync.copy(value)
            end
        end
    end
    state.work_id = state.work_id or saved.work_id
    state.book_id = state.book_id or saved.book_id
    state.document_hash = state.document_hash or saved.document_hash
    if next(state.snapshot) == nil then
        state.snapshot = AnnotationSync.copy(saved.snapshot)
    end
    return state
end

function Coppice:annotationQueueJobs()
    self:loadSettings()
    local jobs = Coppice.settings_obj:readSetting("coppice_annotation_queue", {})
    return type(jobs) == "table" and jobs or {}
end

function Coppice:saveAnnotationQueueJobs(jobs)
    self:loadSettings()
    Coppice.settings_obj:saveSetting("coppice_annotation_queue", jobs or {})
    Coppice.settings_obj:flush()
end

local RECENT_ANNOTATION_CACHE_LIMIT = 200

local function recentAnnotationRecord(item, book_id, document_hash,
        title, path, is_remote_note, reason)
    if type(item) ~= "table" then return nil end
    local kind = item.kind or Annotations.kind(item)
    if kind ~= "highlight" and kind ~= "note" then return nil end
    local timestamp = item.updated_at or item.datetime_updated
        or item.coppice_client_ts or item.client_ts or item.datetime
    return {
        id = item.id or item.coppice_id,
        book_id = book_id,
        book_title = title,
        document_hash = document_hash,
        kind = kind,
        excerpt = item.excerpt or item.text,
        body = item.body or item.note,
        updated_at = timestamp,
        client_ts = item.client_ts or item.coppice_client_ts,
        color = item.color,
        drawer = item.drawer,
        locator = item.locator or Annotations.locator(item, document_hash),
        page = item.page,
        pageno = item.pageno,
        pos0 = AnnotationSync.copy(item.pos0),
        pos1 = AnnotationSync.copy(item.pos1),
        source = item.source,
        device_id = item.device_id,
        local_path = path,
        remote_note = is_remote_note == true,
        reason = reason,
    }
end

local function recentAnnotationKey(item)
    local scope = tostring(item.book_id or item.document_hash or "")
    local id = tostring(item.id or "")
    if id ~= "" then return scope .. "\30" .. id end
    return scope .. "\30" .. tostring(item.updated_at or "")
        .. "\30" .. tostring(item.excerpt or "")
end

function Coppice:cacheRecentAnnotations(items, book_id, document_hash,
        title, path, state)
    self:loadSettings()
    local cached = Coppice.settings_obj:readSetting("coppice_recent_annotations", {})
    if type(cached) ~= "table" then cached = {} end

    for _unused, record in ipairs(cached) do
        if type(record) == "table"
                and (document_hash and record.document_hash == document_hash
                    or book_id and tostring(record.book_id) == tostring(book_id)) then
            title = title or record.book_title or record.title
            path = path or record.local_path
        end
    end

    local keep = {}
    for _unused, record in ipairs(cached) do
        local same_document = document_hash
            and type(record) == "table" and record.document_hash == document_hash
        local same_book = book_id and type(record) == "table"
            and tostring(record.book_id) == tostring(book_id)
        if type(record) == "table" and not same_document and not same_book then
            keep[#keep + 1] = record
        end
    end

    local current = {}
    for _unused, item in ipairs(type(items) == "table" and items or {}) do
        local record = recentAnnotationRecord(item, book_id, document_hash,
            title, path, item and item.remote_note)
        if record then current[recentAnnotationKey(record)] = record end
    end
    for id, entry in pairs(state and state.remote_notes or {}) do
        local record = type(entry) == "table"
            and (type(entry.record) == "table" and entry.record or entry) or nil
        if type(record) == "table" then
            local copy = AnnotationSync.copy(record)
            copy.id = copy.id or id
            copy.book_id = book_id
            copy.document_hash = document_hash
            copy.book_title = title
            copy.local_path = path
            copy.remote_note = true
            copy.reason = type(entry) == "table" and entry.reason or nil
            local normalized = recentAnnotationRecord(copy, book_id,
                document_hash, title, path, true, copy.reason)
            if normalized then current[recentAnnotationKey(normalized)] = normalized end
        end
    end

    for _unused, record in pairs(current) do keep[#keep + 1] = record end
    table.sort(keep, function(left, right)
        local left_time = Annotations.clientTs(left.updated_at, 0)
        local right_time = Annotations.clientTs(right.updated_at, 0)
        if left_time ~= right_time then return left_time > right_time end
        return recentAnnotationKey(left) < recentAnnotationKey(right)
    end)
    for index = #keep, RECENT_ANNOTATION_CACHE_LIMIT + 1, -1 do
        keep[index] = nil
    end
    Coppice.settings_obj:saveSetting("coppice_recent_annotations", keep)
    Coppice.settings_obj:flush()
end

-- Home's "Recent highlights & notes": the newest ones across every book and
-- source (Liseur, Home, Kobo, this device) from the server, newest first.
-- The last server answer is cached for offline use; before the server has
-- ever answered, the device's own recently synced annotations are shown.
function Coppice:recentAnnotationItems(titles, cache_only)
    self:loadSettings()
    if self.ui and self.ui.doc_settings and self.ui.annotation then
        self:queueAnnotationSnapshot()
    end
    local items
    local api = not cache_only and self:client()
    if api and api:isConfigured() then
        local data = api:graphql(Catalog.recentAnnotationsRequest(4))
        local page = type(data) == "table" and data.annotations
        if type(page) == "table" and type(page.items) == "table" then
            items = {}
            for _unused, entry in ipairs(page.items) do
                local mapped = Catalog.serverAnnotation(entry)
                if mapped then items[#items + 1] = mapped end
            end
            Coppice.settings_obj:saveSetting("coppice_server_recent_annotations", items)
            Coppice.settings_obj:flush()
        end
    end
    if not items then
        items = Coppice.settings_obj:readSetting("coppice_server_recent_annotations")
    end
    if type(items) ~= "table" then
        items = Coppice.settings_obj:readSetting("coppice_recent_annotations", {})
    end
    if type(items) ~= "table" then return {} end
    local result = AnnotationSync.copy(items)
    for _unused, item in ipairs(result) do
        if type(item) == "table" then
            local id = item.book_id
            item.title = (id and titles and titles[tostring(id)])
                or item.book_title or item.title
        end
    end
    return result
end

function Coppice:pendingSyncCount()
    local progress = 0
    local queue_ok, progress_queue = pcall(require, "KOSyncQueue")
    if queue_ok and type(progress_queue.count) == "function" then
        local count_ok, count = pcall(progress_queue.count, progress_queue)
        if count_ok then progress = math.max(0, tonumber(count) or 0) end
    end
    local pending = {}
    local function include_queue(queue, document_hash)
        if type(queue) ~= "table" then return end
        for id in pairs(queue) do
            pending[tostring(document_hash or "") .. "\30" .. tostring(id)] = true
        end
    end
    for key, job in pairs(self:annotationQueueJobs()) do
        if type(job) == "table" then
            local state = AnnotationSync.newState(job.state)
            include_queue(state.queue, job.document_hash or key)
        end
    end
    local doc_settings = self.ui and self.ui.doc_settings
    if doc_settings then
        local document_hash = KoSync.documentHash(doc_settings) or ""
        include_queue(AnnotationSync.loadState(doc_settings).queue, document_hash)
    end
    local annotations = 0
    for _ in pairs(pending) do annotations = annotations + 1 end
    return progress + annotations
end

function Coppice:queueAnnotationSnapshot()
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings then return nil end
    self:loadSettings()
    local items = self.ui.annotation and self.ui.annotation.annotations or {}
    local document_hash = KoSync.documentHash(doc_settings) or ""
    local book_id = self:linkedBookId()
    local state = AnnotationSync.loadState(doc_settings)
    local jobs = self:annotationQueueJobs()
    for old_key, job in pairs(jobs) do
        if type(job) == "table" and job.document_hash == document_hash then
            state = mergeAnnotationState(state, job.state)
            book_id = book_id or job.book_id
            if old_key ~= AnnotationSync.bookKey(book_id, document_hash) then
                jobs[old_key] = nil
            end
        end
    end
    state = AnnotationSync.queueSnapshot(state, items, book_id, document_hash)
    local page_count = self.ui.document
        and self.ui.document:getPageCount() or nil
    AnnotationSync.saveState(doc_settings, state)
    local key = AnnotationSync.bookKey(book_id, document_hash)
    jobs[key] = {
        book_id = book_id,
        work_id = state.work_id,
        document_hash = document_hash,
        page_count = page_count,
        items = AnnotationSync.copy(items),
        state = AnnotationSync.exportState(state),
    }
    self:saveAnnotationQueueJobs(jobs)
    self:cacheRecentAnnotations(items, book_id, document_hash,
        self.ui.doc_props and self.ui.doc_props.display_title,
        self.ui.document and self.ui.document.file, state)
    return document_hash, key, state
end

function Coppice:storeAnnotationJob(key, state, items, book_id,
        document_hash, page_count)
    local jobs = self:annotationQueueJobs()
    for old_key, job in pairs(jobs) do
        if old_key ~= key and type(job) == "table"
                and job.document_hash == document_hash then
            jobs[old_key] = nil
        end
    end
    if next(state.queue) == nil then
        jobs[key] = nil
    else
        state.snapshot = AnnotationSync.copy(items or {})
        jobs[key] = {
            book_id = book_id,
            work_id = state.work_id,
            document_hash = document_hash,
            page_count = page_count,
            items = AnnotationSync.copy(items or {}),
            state = AnnotationSync.exportState(state),
        }
    end
    self:saveAnnotationQueueJobs(jobs)
end

function Coppice:resolveQueuedBookId(api, job)
    if type(job.book_id) == "string" and job.book_id ~= "" then
        return job.book_id
    end
    if type(job.document_hash) ~= "string" or job.document_hash == "" then
        return nil, "no_document_hash"
    end
    local items, err, code = api:continueReading(50)
    if not items then return nil, err, code end
    for _unused, item in ipairs(items) do
        if item.koreaderHash == job.document_hash
                and type(item.mediaId) == "string" and item.mediaId ~= "" then
            return item.mediaId
        end
    end
    return nil, "not_in_reading_list"
end

function Coppice:drainAnnotationJobs(exclude_document_hash)
    self:loadSettings()
    local api = self:client()
    local secret = Settings.credential(self.settings.liseur_secret)
    if not api or not api:isConfigured() or not secret then return false end
    local jobs = self:annotationQueueJobs()
    local keys = {}
    for key in pairs(jobs) do table.insert(keys, key) end
    table.sort(keys)
    for _unused, old_key in ipairs(keys) do
        local job = jobs[old_key]
        if type(job) == "table"
                and job.document_hash ~= exclude_document_hash then
            local state = AnnotationSync.newState(job.state)
            mergeAnnotationState(state, job.state)
            local items = type(job.items) == "table" and job.items
                or state.snapshot or {}
            local book_id, book_err, book_code = self:resolveQueuedBookId(api, job)
            if book_id then
                local work_id = state.work_id or job.work_id
                if not work_id then
                    local resolved, response_or_error, resolve_code_or_error =
                        api:liseurResolveWork(secret, book_id)
                    work_id = resolved
                    if not work_id then
                        book_err = response_or_error or "no_work_id"
                        book_code = resolve_code_or_error
                    end
                end
                if work_id then
                    state.book_id = book_id
                    state.work_id = work_id
                    state.document_hash = job.document_hash
                    local options = {
                        work_id = work_id,
                        edition_sha = job.edition_sha,
                        document_hash = job.document_hash,
                        page_count = job.page_count,
                        digest = md5,
                        items = items,
                        onRecreated = function(old_id, new_id)
                            local item = AnnotationSync.currentItem(state, old_id,
                                items, { document_hash = job.document_hash,
                                    digest = md5 })
                            if item then
                                item.coppice_id = new_id
                                local local_id = Annotations.localId(item,
                                    job.document_hash, md5)
                                if local_id then state.id_map[local_id] = new_id end
                            end
                        end,
                    }
                    AnnotationSync.plan(items, state, options)
                    local ok, result = AnnotationSync.drain(api, secret, state,
                        options)
                    state.snapshot = AnnotationSync.copy(items)
                    if ok and next(state.queue) == nil then
                        jobs[old_key] = nil
                    else
                        local key = AnnotationSync.bookKey(book_id,
                            job.document_hash)
                        if key ~= old_key then jobs[old_key] = nil end
                        jobs[key] = {
                            book_id = book_id,
                            work_id = work_id,
                            document_hash = job.document_hash,
                            page_count = job.page_count,
                            items = AnnotationSync.copy(items),
                            state = AnnotationSync.exportState(state),
                        }
                        if result.failed then
                            logger.dbg("Coppice: annotation queue retained",
                                result.failed.error or "sync_failed")
                        end
                    end
                else
                    logger.dbg("Coppice: annotation queue awaits work resolution",
                        book_err or "no_work_id", book_code)
                end
            else
                logger.dbg("Coppice: annotation queue awaits book resolution",
                    book_err or "no_book_id", book_code)
            end
        end
    end
    self:saveAnnotationQueueJobs(jobs)
    return true
end

function Coppice:performAnnotationSync(pull, interactive)
    self:loadSettings()
    local doc_settings = self.ui and self.ui.doc_settings
    if not doc_settings or not self.ui.annotation then
        if interactive then warn(_("Open a book before syncing annotations.")) end
        return false
    end
    local api = self:client()
    local secret = Settings.credential(self.settings.liseur_secret)
    if not api or not api:isConfigured() or not secret then
        if interactive then warn(_("Pair this device before syncing annotations.")) end
        return false
    end
    local book_id, book_err, book_code = self:bookId(api)
    if not book_id then
        if interactive then
            if book_err == "no_partial_md5" or book_err == "not_in_reading_list" then
                warn(_("Link this book to a Coppice book before syncing annotations."))
            else
                warnApi(_("Could not look up this book on Coppice."),
                    book_err, book_code)
            end
        end
        return false
    end
    local work_id, response_or_error, resolve_code_or_error, resolve_http_code =
        api:liseurResolveWork(secret, book_id)
    if not work_id then
        if interactive then
            warnApi(_("Coppice could not resolve this book's work id."),
                response_or_error or resolve_code_or_error,
                resolve_code_or_error or resolve_http_code)
        end
        return false
    end
    local edition_sha
    for _unused, identifier in ipairs(type(response_or_error.identifiers) == "table"
            and response_or_error.identifiers or {}) do
        if type(identifier) == "table" and identifier.kind == "sha256"
                and type(identifier.value) == "string" then
            edition_sha = identifier.value
        end
    end
    local document_hash = KoSync.documentHash(doc_settings) or ""
    local items = self.ui.annotation.annotations or {}
    local page_count = self.ui.document
        and self.ui.document:getPageCount() or nil
    local state = AnnotationSync.loadState(doc_settings)
    local jobs = self:annotationQueueJobs()
    for _unused, job in pairs(jobs) do
        if type(job) == "table" and job.document_hash == document_hash then
            state = mergeAnnotationState(state, job.state)
        end
    end
    state.work_id = work_id
    state.book_id = book_id
    state.document_hash = document_hash
    state.snapshot = AnnotationSync.copy(items)
    local job_key = AnnotationSync.bookKey(book_id, document_hash)
    AnnotationSync.saveState(doc_settings, state)

    local options
    options = {
        api = api,
        secret = secret,
        work_id = work_id,
        edition_sha = edition_sha,
        document_hash = document_hash,
        page_count = page_count,
        digest = md5,
        state = state,
        items = items,
        annotation = self.ui.annotation,
        ui = self.ui,
        document = self.ui.document,
        default_drawer = self.ui.view and self.ui.view.highlight
            and self.ui.view.highlight.saved_drawer or "lighten",
        emit = function(modified)
            self._annotation_sync_applying = true
            local ok, error_message = pcall(function()
                local Event = require("ui/event")
                self.ui:handleEvent(Event:new("AnnotationsModified", modified))
            end)
            self._annotation_sync_applying = nil
            if not ok then
                logger.warn("Coppice: could not publish imported annotation",
                    tostring(error_message))
            end
        end,
        onRecreated = function(old_id, new_id)
            local item = AnnotationSync.currentItem(state, old_id, items, options)
            if item then
                item.coppice_id = new_id
                local local_id = Annotations.localId(item, document_hash, md5)
                if local_id then state.id_map[local_id] = new_id end
            end
        end,
        persist = function(next_state)
            next_state.snapshot = next(next_state.queue) ~= nil
                and AnnotationSync.copy(items) or {}
            AnnotationSync.saveState(doc_settings, next_state)
            self:storeAnnotationJob(job_key, next_state, items,
                book_id, document_hash, page_count)
        end,
    }
    local sync = AnnotationSync.new(options)
    local ok, result = sync:run(pull)
    self:cacheRecentAnnotations(items, book_id, document_hash,
        self.ui.doc_props and self.ui.doc_props.display_title,
        self.ui.document and self.ui.document.file, state)
    for reason, count in pairs(result.skipped or {}) do
        logger.warn("Coppice: annotation changes not synchronized", count, reason)
    end
    if interactive then
        if result.failed then
            warnApi(_("Annotation sync failed; pending changes remain queued."),
                result.failed.error, result.failed.code)
        else
            local lines = {
                T(_("Synced %1 annotations; %2 already current; %3 deletions."),
                    result.applied, result.duplicate, result.deleted),
            }
            if result.pull then
                if result.pull.imported > 0 or result.pull.updated > 0 then
                    table.insert(lines, T(_("Imported %1 and updated %2 remote annotations."),
                        result.pull.imported, result.pull.updated))
                end
                if result.pull.removed > 0 then
                    table.insert(lines, T(_("Removed %1 annotations deleted on Coppice."),
                        result.pull.removed))
                end
            end
            local remote_count = 0
            for _ in pairs(state.remote_notes) do remote_count = remote_count + 1 end
            if remote_count > 0 then
                table.insert(lines, T(_("%1 annotations could not be imported safely; see Remote notes."),
                    remote_count))
            end
            for reason, count in pairs(result.skipped or {}) do
                table.insert(lines, T(_("Skipped %1: %2"), count, reason))
            end
            inform(table.concat(lines, "\n"))
        end
    end
    return ok, result
end

function Coppice:syncAnnotationsNow()
    if not self.ui or not self.ui.doc_settings then
        warn(_("Open a book before syncing annotations."))
        return true
    end
    self:queueAnnotationSnapshot()
    NetworkMgr:runWhenConnected(function()
        self:performAnnotationSync(true, true)
    end)
    return true
end

function Coppice:onCoppiceSyncAnnotations()
    return self:syncAnnotationsNow()
end

function Coppice:onReaderReady()
    self:openPendingAnnotationAction()
    self:queueAnnotationSnapshot()
    NetworkMgr:runWhenConnected(function()
        self:performAnnotationSync(true, false)
    end)
end

function Coppice:onAnnotationsModified()
    if self._annotation_sync_applying or not self.ui
            or not self.ui.doc_settings then return end
    if self.annotation_sync_task then UIManager:unschedule(self.annotation_sync_task) end
    self.annotation_sync_task = function()
        self.annotation_sync_task = nil
        self:queueAnnotationSnapshot()
        NetworkMgr:runWhenConnected(function()
            self:drainAnnotationJobs()
        end)
    end
    UIManager:scheduleIn(2, self.annotation_sync_task)
end

function Coppice:onCloseDocument()
    if self.annotation_sync_task then
        UIManager:unschedule(self.annotation_sync_task)
        self.annotation_sync_task = nil
    end
    if self.ui and self.ui.doc_settings then
        self:queueAnnotationSnapshot()
        NetworkMgr:runWhenConnected(function()
            self:drainAnnotationJobs()
        end)
    end
end

function Coppice:onSuspend()
    if self.ui and self.ui.doc_settings then
        self:queueAnnotationSnapshot()
        NetworkMgr:runWhenConnected(function()
            self:drainAnnotationJobs()
        end)
    end
end

function Coppice:onNetworkConnected()
    local document_hash
    if self.ui and self.ui.doc_settings then
        document_hash = self:queueAnnotationSnapshot()
        UIManager:scheduleIn(0.5, function()
            self:performAnnotationSync(true, false)
            self:drainAnnotationJobs(document_hash)
        end)
    else
        UIManager:scheduleIn(0.5, function()
            self:drainAnnotationJobs()
        end)
    end
end

function Coppice:showRemoteNotes(book)
    local requested_book_id = book and (book.book_id or book.id)
    if book then
        local path = self:localBookPath(book)
        if path and (not self.ui or not self.ui.document
                or self.ui.document.file ~= path) then
            Coppice.pending_annotation_action = {
                kind = "remote_notes",
                item = book,
                local_path = path,
            }
            return self:openDownloadedFile(path)
        end
    end

    self:loadSettings()
    local entries = {}
    local function add_record(id, record, reason)
        if type(record) ~= "table" then return end
        local record_book_id = record.book_id or record.media_id
        if requested_book_id and tostring(record_book_id or "")
                ~= tostring(requested_book_id) then
            return
        end
        local entry_key = tostring(record_book_id or "") .. "\30" .. tostring(id or record.id or "")
        entries[entry_key] = {
            id = tostring(id or record.id or ""),
            record = AnnotationSync.copy(record),
            reason = reason,
        }
    end

    local cached = Coppice.settings_obj:readSetting("coppice_recent_annotations", {})
    for _unused, record in ipairs(type(cached) == "table" and cached or {}) do
        if type(record) == "table" and record.remote_note then
            add_record(record.id, record, record.reason)
        end
    end

    local doc_settings = self.ui and self.ui.doc_settings
    if doc_settings then
        local state = AnnotationSync.loadState(doc_settings)
        local document_hash = KoSync.documentHash(doc_settings) or ""
        for _unused, job in pairs(self:annotationQueueJobs()) do
            if type(job) == "table" and job.document_hash == document_hash then
                state = mergeAnnotationState(state, job.state)
            end
        end
        local title = self.ui.doc_props and self.ui.doc_props.display_title
        for id, entry in pairs(state.remote_notes) do
            local record = type(entry) == "table"
                and (type(entry.record) == "table" and entry.record or entry) or nil
            if type(record) == "table" then
                record = AnnotationSync.copy(record)
                record.book_id = record.book_id or state.book_id or self:linkedBookId()
                record.book_title = record.book_title or title
                record.document_hash = record.document_hash or document_hash
                local reason = type(entry) == "table" and entry.reason or nil
                add_record(id, record, reason)
            end
        end
    end

    local ids = {}
    for id in pairs(entries) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then
        inform(_("There are no remote annotations that need safe-import review."))
        return true
    end
    local rows = {}
    for _unused, id in ipairs(ids) do
        local entry = entries[id]
        local record = entry.record
        local excerpt = record.excerpt or ""
        local body = record.body or ""
        local text = (record.kind or _("Remote note")) .. " — " .. entry.id
            .. "\n" .. _("This annotation could not be imported safely.")
        if record.book_title then
            text = text .. "\n" .. T(_("Book: %1"), record.book_title)
        end
        if entry.reason then text = text .. "\n" .. T(_("Reason: %1"), entry.reason) end
        if excerpt ~= "" then text = text .. "\n" .. excerpt end
        if body ~= "" then text = text .. "\n" .. body end
        rows[#rows + 1] = { text = text }
    end
    local Menu = require("ui/widget/menu")
    self.remote_notes_menu = Menu:new{
        title = _("Remote notes"),
        item_table = rows,
        multilines_forced = true,
        items_per_page = 8,
        covers_fullscreen = true,
        is_borderless = true,
        onMenuSelect = function() return true end,
        close_callback = function() UIManager:close(self.remote_notes_menu) end,
    }
    UIManager:show(self.remote_notes_menu)
    return true
end

return Coppice
