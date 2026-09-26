--[[--
Pure helpers for the Coppice companion pairing contract.

A pairing response can contain more than one credential. Never infer the
credential lane from array order: kind and protocol are the stable contract.
The singular `credential` field is accepted only as a compatibility fallback
for servers predating the dual-credential response.
]]

local Settings = require("coppice_settings")
local text = Settings.text
local safeCredential = Settings.credential

local Pairing = {}
local API_PROTOCOLS = {
    koreader = true,
    api = true,
    opds = true,
}

local function credentialList(response)
    if type(response) ~= "table" then return {} end
    local list = {}
    if type(response.credentials) == "table" then
        for _unused, credential in ipairs(response.credentials) do
            list[#list + 1] = credential
        end
    end
    -- Add the singular primary API credential as a compatibility lane when
    -- the additive list is absent or incomplete.
    if type(response.credential) == "table" then
        list[#list + 1] = response.credential
    end
    return list
end


--- Selects both lanes and metadata without depending on server list order.
---
--- Returns `nil, reason` when the response cannot safely configure the
--- companion. A partial response is rejected: losing either lane would leave
--- the device apparently paired but unable to export annotations or sync
--- progress.
function Pairing.credentials(response)
    if type(response) ~= "table" or response.status ~= "approved" then
        return nil, "not_approved"
    end

    local result = {
        api_key = nil,
        liseur_secret = nil,
        username = text(response.username),
        device_id = type(response.device) == "table"
            and text(response.device.id) or nil,
        device_name = type(response.device) == "table"
            and text(response.device.name) or nil,
        endpoints = type(response.endpoints) == "table"
            and response.endpoints or {},
    }

    local has_api_kind = false
    local has_liseur_kind = false
    for _unused, credential in ipairs(credentialList(response)) do
        if type(credential) == "table" then
            local kind = text(credential.kind)
            local protocol = text(credential.protocol)
            local secret = safeCredential(credential.secret)
            if kind == "api_key" and API_PROTOCOLS[protocol] and secret then
                result.api_key = secret
                has_api_kind = true
            elseif kind == "liseur_token" and protocol == "liseur" and secret then
                result.liseur_secret = secret
                has_liseur_kind = true
            end
        end
    end

    -- The username is metadata, not an authentication secret. Prefer the
    -- server's explicit value; otherwise select an endpoint by protocol/URL,
    -- never by whichever endpoint happened to be first.
    if not result.username then
        local best_name, best_rank = nil, -1
        for _unused, endpoint in ipairs(result.endpoints) do
            if type(endpoint) == "table" then
                local protocol = text(endpoint.protocol)
                local url = text(endpoint.url) or ""
                local rank = (protocol == "koreader" and 3)
                    or (protocol == "api" and 2)
                    or (protocol == "opds" and 1)
                    or (url:match("/api/?$") and 2)
                    or (url:match("/opds/") and 1)
                    or 0
                local name = text(endpoint.username)
                if name and (rank > best_rank
                        or (rank == best_rank and (not best_name or name < best_name)))
                then
                    best_name, best_rank = name, rank
                end
            end
        end
        result.username = best_name
    end
    result.username = result.username or "coppice"

    if not has_api_kind then return nil, "missing_api_key" end
    if not has_liseur_kind then return nil, "missing_liseur_token" end
    return result
end

function Pairing.statusMessage(status, expires_at)
    if status == "pending" then
        return "Waiting for approval."
    elseif status == "approved" then
        return "Approved. Credentials received."
    elseif status == "denied" then
        return "Pairing was denied. Start a new pairing to try again."
    elseif status == "expired" then
        return "Pairing expired. Start a new pairing to try again."
    end
    return "Pairing status is unavailable. Start a new pairing to try again."
end

function Pairing.pollInterval(response, fallback)
    local value = type(response) == "table" and tonumber(response.poll_interval_secs)
    if not value or value ~= value or value < 1 then value = fallback or 2 end
    if value > 30 then value = 30 end
    return math.floor(value)
end

--- Groups a six-digit code as `123 456` so it is easy to read aloud and type.
function Pairing.formatCode(code)
    local digits = tostring(code or ""):gsub("%D", "")
    if #digits ~= 6 then return tostring(code or "------") end
    return digits:sub(1, 3) .. " " .. digits:sub(4, 6)
end

--- UTC epoch seconds for an RFC 3339 `YYYY-MM-DDTHH:MM:SS[.fff]Z` timestamp,
--- or nil. Only the UTC `Z` form the server emits is accepted.
function Pairing.parseUtc(value)
    if type(value) ~= "string" then return nil end
    local y, mo, d, h, mi, s = value:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)[%.%d]*Z$")
    if not y then return nil end
    -- Days since the epoch via the civil-from-days inverse (no os.time/TZ).
    y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
    if mo <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (mo + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

--- Short, human expiry text: `expires in 9 min`, `expires in 40 s`,
--- `expired`, or nil when the timestamp is unusable.
function Pairing.expiresIn(expires_at, now)
    local at = Pairing.parseUtc(expires_at)
    if not at or not now then return nil end
    local left = at - now
    if left <= 0 then return "expired" end
    if left < 60 then return string.format("expires in %d s", left) end
    return string.format("expires in %d min", math.ceil(left / 60))
end

return Pairing
