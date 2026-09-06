--[[--
Points KOReader's built-in `kosync` plugin at Stump, and pushes/pulls
progress directly.

Two paths exist on purpose.

**The built-in client.** KOReader already ships a kosync client that pushes on
page turn, suspend and document close, debounced, with prompt/silent/disable
strategies per direction. Stump implements exactly the routes it calls, so the
right answer for automatic background sync is to *configure* that client, not
to reimplement its scheduling. Its settings live in
`<settings dir>/kosync.lua` under the key `settings`, and the three fields
that matter are:

* `custom_server` — `<base>/koreader/<api_key>`. Stump authenticates kosync by
  the API key in the path (`api_key_middleware`), so the key is part of the
  base URL. `KOSyncClient` appends `/users/auth`, `/syncs/progress` and
  `/syncs/progress/:document` to it, which are Stump's three routes verbatim.
* `username` / `userkey` — required non-nil for the built-in client to sync at
  all (`KOSync:updateProgress` returns early without them), and ignored by
  Stump: KOReader sends `md5(password)`, which cannot be checked against a
  bcrypt hash. The Stump username and `md5(api_key)` are written so the values
  are at least meaningful to a human reading the settings file.
* `checksum_method = 0` (BINARY) — Stump matches the partial-MD5
  `media.koreader_hash`. Left on FILENAME, every push 404s.

**Direct push/pull.** The built-in client cannot be driven from another
plugin (it debounces on its own timers and its client object is local), and a
"sync now, tell me what happened" action has to report a result. So this
module also speaks the three routes itself for the explicit menu actions.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local md5 = require("ffi/sha2").md5
local logger = require("logger")

local Url = require("stump_url")

local KoSync = {}

KoSync.CHECKSUM_BINARY = 0
KoSync.SETTINGS_FILE = "kosync.lua"

local function kosyncSettingsPath()
    return DataStorage:getSettingsDir() .. "/" .. KoSync.SETTINGS_FILE
end

--- The exact table written into KOReader's kosync settings.
---
--- Pure, so the mapping can be checked without touching the filesystem.
function KoSync.settingsPatch(base, api_key, username)
    local server = Url.kosync(base, api_key)
    if not server then return nil, "no_api_key" end
    return {
        custom_server = server,
        username = (username and username ~= "") and username or "stump",
        userkey = md5(api_key),
        checksum_method = KoSync.CHECKSUM_BINARY,
    }
end

--- Writes the patch into `<settings dir>/kosync.lua`, preserving every other
--- kosync preference (sync strategies, page interval, auto-sync).
---
--- A separate `LuaSettings` handle is opened rather than reaching into the
--- running plugin: the built-in plugin holds its own handle and flushes on
--- `onFlushSettings`, so writing the file and letting it be re-read on next
--- start is the only way to change it from outside without a race. The user
--- is told to restart KOReader for that reason.
function KoSync.configure(base, api_key, username)
    local patch, err = KoSync.settingsPatch(base, api_key, username)
    if not patch then return nil, err end

    local settings_obj = LuaSettings:open(kosyncSettingsPath())
    local existing = settings_obj:readSetting("settings") or {}
    for key, value in pairs(patch) do
        existing[key] = value
    end
    settings_obj:saveSetting("settings", existing)
    settings_obj:flush()
    logger.info("Stump: configured kosync custom server", patch.custom_server)
    return patch
end

--- True when the built-in client is pointed at this Stump and set to BINARY.
function KoSync.isConfiguredFor(base, api_key)
    local expected = Url.kosync(base, api_key)
    if not expected then return false end
    local settings_obj = LuaSettings:open(kosyncSettingsPath())
    local existing = settings_obj:readSetting("settings")
    if not existing then return false end
    return existing.custom_server == expected
        and existing.checksum_method == KoSync.CHECKSUM_BINARY
        and (existing.username or "") ~= ""
        and (existing.userkey or "") ~= ""
end

--- The document identity Stump matches: KOReader's partial MD5, which it
--- stores in the book's sidecar as `partial_md5_checksum`.
---
--- Deliberately not the filename MD5: Stump never computes that, so a
--- filename-matched push is a 404 by construction.
function KoSync.documentHash(doc_settings)
    if not doc_settings then return nil end
    local hash = doc_settings:readSetting("partial_md5_checksum")
    if type(hash) ~= "string" or hash == "" then return nil end
    return hash
end

return KoSync
