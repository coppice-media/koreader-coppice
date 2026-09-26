--[[--
Validation for persisted and optional Coppice plugin settings.

Settings are local input, not trusted just because KOReader stored them: old,
partial, or edited Lua settings must not turn credentials into headers/paths or
an invalid server string into a malformed request.
]]

local Url = require("coppice_url")

local Settings = {}

function Settings.text(value, max_bytes)
    if type(value) ~= "string" or value == "" or #value > (max_bytes or 255)
            or value:find("[%c]") then
        return nil
    end
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

function Settings.credential(value)
    if type(value) ~= "string" or value == "" or #value > 4096
            or value:find("[%c%s]") then
        return nil
    end
    return value
end

local function path(value)
    if type(value) ~= "string" or value == "" or #value > 4096
            or value:find("[%c]") then
        return nil
    end
    return value
end

local function interval(value)
    value = tonumber(value)
    if not value or value ~= value or value < 1 or value > 30 then return nil end
    return math.floor(value)
end

function Settings.validate(saved, config)
    saved = type(saved) == "table" and saved or {}
    config = type(config) == "table" and config or {}

    local result = {
        server = Url.normalizeBase(saved.server),
        username = Settings.text(saved.username),
        api_key = Settings.credential(saved.api_key),
        liseur_secret = Settings.credential(saved.liseur_secret),
        device_id = Settings.text(saved.device_id),
        device_name = Settings.text(saved.device_name),
        download_dir = path(saved.download_dir),
        pairing_id = Settings.credential(saved.pairing_id),
        pairing_nonce = Settings.credential(saved.pairing_nonce),
        pairing_code = type(saved.pairing_code) == "string"
                and saved.pairing_code:match("^%d%d%d%d%d%d$")
            and saved.pairing_code or nil,
        pairing_expires_at = Settings.text(saved.pairing_expires_at, 64),
        pairing_poll_interval = interval(saved.pairing_poll_interval),
        -- Opening Coppice Home when KOReader starts is on unless the user
        -- turned it off; `nil` (older settings files) means on.
        open_on_start = saved.open_on_start ~= false,
    }

    if not result.server then result.server = Url.normalizeBase(config.server) end
    if not result.download_dir then result.download_dir = path(config.download_dir) end
    if not result.device_name then
        result.device_name = Settings.text(config.device_name)
    end
    return result
end

return Settings
