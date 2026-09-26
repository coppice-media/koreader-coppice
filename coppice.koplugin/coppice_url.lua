--[[--
URL construction for the four Coppice surfaces this plugin speaks to.

Pure functions only: no `require` of anything KOReader-specific, no I/O. That
is deliberate — these are the parts most likely to be wrong (a doubled slash,
an unescaped query value, a reverse-proxy origin leaking through an OPDS
`href`) and the parts cheapest to check outside a device.

The four surfaces, and why they are not one:

* `/opds/v2.0/...`   catalogue browsing. Accepts `Authorization: Basic`.
* `/api/v2/...`      dashboard, file download, thumbnails. Rejects Basic;
                     wants `Authorization: Bearer <api key>`.
* `/koreader/{key}`  kosync progress. The API key is *in the path*.
* `/v1/...`          liseur-sync annotations. `Authorization: Bearer <device
                     token>` issued by the approved Coppice pairing.
]]

local Url = {}

local UNRESERVED = "^[A-Za-z0-9%-_%.~]$"

--- Percent-encodes one query component (RFC 3986 unreserved set kept).
function Url.escape(value)
    if value == nil then return "" end
    return (tostring(value):gsub("[^A-Za-z0-9%-_%.~]", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

--- Builds a stable query string: keys are sorted so the same table always
--- produces the same URL (cache friendliness, and comparable log lines).
--- `nil` and `false` values are dropped; `true` becomes `key=true`.
function Url.query(params)
    if type(params) ~= "table" then return "" end
    local keys = {}
    for key, value in pairs(params) do
        if value ~= nil and value ~= false then
            table.insert(keys, key)
        end
    end
    if #keys == 0 then return "" end
    table.sort(keys)
    local parts = {}
    for _unused, key in ipairs(keys) do
        table.insert(parts, Url.escape(key) .. "=" .. Url.escape(params[key]))
    end
    return table.concat(parts, "&")
end

local function validPort(port)
    if not port then return true end
    local value = tonumber(port)
    return value ~= nil and value >= 1 and value <= 65535
end

local function validAuthority(authority)
    if type(authority) ~= "string" or authority == ""
            or authority:find("[%c%s@]") then
        return false
    end
    local host, port = authority:match("^%[([0-9A-Fa-f:.]+)%]:(%d+)$")
    if not host then
        host = authority:match("^%[([0-9A-Fa-f:.]+)%]$")
    end
    if host then
        return host:find(":", 1, true) ~= nil and validPort(port)
    end

    host, port = authority:match("^([A-Za-z0-9%.%-]+):(%d+)$")
    if not host then
        host = authority:match("^([A-Za-z0-9%.%-]+)$")
    end
    if not host or #host > 253 or host:sub(1, 1) == "."
            or host:sub(-1) == "." or host:find("..", 1, true) then
        return false
    end
    for label in host:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-"
                or label:sub(-1) == "-"
                or not label:match("^[A-Za-z0-9%-]+$") then
            return false
        end
    end
    return validPort(port)
end

local function validPath(path)
    if path:find("[%c%s]") or path:find("\\", 1, true)
            or path:find("//", 1, true) then
        return false
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return false end
    end
    return true
end

--- Normalizes what a user typed into a server base URL, or nil when it cannot
--- be one. Credentials, query strings and fragments are never accepted.
---
--- Trailing slashes are stripped so every caller can concatenate a path that
--- starts with `/` without producing `//`. A pasted Coppice API, OPDS or
--- KOSync endpoint is trimmed back to the server root.
function Url.normalizeBase(input)
    if type(input) ~= "string" then return nil end
    local url = input:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" or url:find("[%c%s]") then return nil end
    local scheme, authority, path =
        url:match("^(https?)://([^/?#]+)([^?#]*)$")
    if not scheme or not validAuthority(authority) then return nil end
    path = path:gsub("/+$", "")
    if not validPath(path) then return nil end
    path = path:gsub("/opds/v2%.0.*$", "")
    path = path:gsub("/opds/v1%.2.*$", "")
    path = path:gsub("/koreader/[^/]*$", "")
    path = path:gsub("/api/v2.*$", "")
    path = path:gsub("/+$", "")
    return scheme .. "://" .. authority .. path
end

--- Splits `scheme://authority` off an absolute HTTP(S) URL.
function Url.origin(url)
    if type(url) ~= "string" or url:find("[%c%s]")
            or url:find("\\", 1, true) then
        return nil
    end
    local scheme, authority =
        url:match("^(https?)://([^/%?#]+)")
    if not scheme or not validAuthority(authority) then return nil end
    return scheme .. "://" .. authority
end
function Url.sameOrigin(base, url)
    local expected = Url.origin(base)
    local actual = Url.origin(url)
    return expected ~= nil and actual ~= nil
        and expected:lower() == actual:lower()
end

--- Forces `base`'s origin onto a safe HTTP(S) href. Unsupported schemes,
--- userinfo and malformed absolute URLs are rejected rather than requested.
function Url.rebase(base, href)
    local normalized_base = Url.normalizeBase(base)
    if type(href) ~= "string" or href == "" or not normalized_base
            or href:find("[%c%s]") or href:find("\\", 1, true) then
        return nil
    end
    local origin = Url.origin(href)
    if origin then
        local suffix = href:sub(#origin + 1)
        if suffix == "" then suffix = "/" end
        return normalized_base .. suffix
    end
    if href:match("^[A-Za-z][A-Za-z0-9%.%+%-]*:") then return nil end
    if href:sub(1, 1) == "/" then
        return normalized_base .. href
    end
    return normalized_base .. "/" .. href
end

local function withQuery(url, params)
    local query = Url.query(params)
    if query == "" then return url end
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. query
end

--- `<base>/opds/v2.0<path>` plus an optional query table.
function Url.opds(base, path, params)
    return withQuery(base .. "/opds/v2.0" .. (path or ""), params)
end

--- `<base>/api/v2<path>` plus an optional query table.
function Url.api(base, path, params)
    return withQuery(base .. "/api/v2" .. (path or ""), params)
end

--- `<base>/v1<path>` — the liseur-sync annotation lane.
function Url.liseur(base, path, params)
    return withQuery(base .. "/v1" .. (path or ""), params)
end

--- The value KOReader's built-in kosync plugin wants in "Custom sync server".
--- Coppice authenticates kosync by the API key in the path, so the key is part
--- of the base URL rather than a header.
function Url.kosync(base, api_key)
    if type(api_key) ~= "string" or api_key == "" then return nil end
    local root = Url.normalizeBase(base)
    if not root then return nil end
    return root .. "/koreader/" .. Url.escape(api_key)
end

--- The kosync routes, spelled out so this plugin can push and pull progress
--- itself instead of only configuring the built-in client.
function Url.kosyncAuth(base, api_key)
    local root = Url.kosync(base, api_key)
    return root and (root .. "/users/auth")
end

function Url.kosyncPutProgress(base, api_key)
    local root = Url.kosync(base, api_key)
    return root and (root .. "/syncs/progress")
end

function Url.kosyncGetProgress(base, api_key, document)
    local root = Url.kosync(base, api_key)
    if not root or type(document) ~= "string" or document == "" then return nil end
    return root .. "/syncs/progress/" .. Url.escape(document)
end

return Url
