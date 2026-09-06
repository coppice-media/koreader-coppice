--[[--
URL construction for the four Stump surfaces this plugin speaks to.

Pure functions only: no `require` of anything KOReader-specific, no I/O. That
is deliberate — these are the parts most likely to be wrong (a doubled slash,
an unescaped query value, a reverse-proxy origin leaking through an OPDS
`href`) and the parts cheapest to check outside a device.

The four surfaces, and why they are not one:

* `/opds/v2.0/...`   catalogue browsing. Accepts `Authorization: Basic`.
* `/api/v2/...`      dashboard, file download, thumbnails. Rejects Basic;
                     wants `Authorization: Bearer <api key>` or a session
                     cookie.
* `/koreader/{key}`  kosync progress. The API key is *in the path*.
* `/v1/...`          liseur-sync annotations. `Authorization: Bearer <device
                     secret>`, minted from a username/password login.
]]

local Url = {}

local UNRESERVED = "^[A-Za-z0-9%-_%.~]$"

--- Percent-encodes one query component (RFC 3986 unreserved set kept).
function Url.escape(value)
    if value == nil then return "" end
    return (tostring(value):gsub(".", function(char)
        if char:match(UNRESERVED) then return char end
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
    for _, key in ipairs(keys) do
        table.insert(parts, Url.escape(key) .. "=" .. Url.escape(params[key]))
    end
    return table.concat(parts, "&")
end

--- Normalizes what a user typed into a server base URL, or nil when it cannot
--- be one. A missing scheme is *not* guessed: a bare host would silently
--- produce a request to a relative path.
---
--- Trailing slashes are stripped so every caller can concatenate a path that
--- starts with `/` without producing `//`. A pasted deep link (the OPDS
--- catalogue, the kosync endpoint from the Stump setup guide) is trimmed back
--- to the server root, because that is what every other surface hangs off.
function Url.normalizeBase(input)
    if type(input) ~= "string" then return nil end
    local url = input:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    if not url:match("^https?://[^/]") then return nil end
    url = url:gsub("/+$", "")
    -- Paths a user is likely to paste from the Stump docs or its UI.
    url = url:gsub("/opds/v2%.0.*$", "")
    url = url:gsub("/opds/v1%.2.*$", "")
    url = url:gsub("/koreader/[^/]*$", "")
    url = url:gsub("/api/v2.*$", "")
    url = url:gsub("/+$", "")
    if not url:match("^https?://[^/]") then return nil end
    return url
end

--- Splits `scheme://authority` off an absolute http(s) URL.
function Url.origin(url)
    if type(url) ~= "string" then return nil end
    local origin = url:match("^(https?://[^/%?#]+)")
    return origin
end

--- Forces `base`'s origin onto `href`.
---
--- Stump builds OPDS `href`s as absolute URLs from the *request* origin
--- (`OPDSLinkFinalizer`). Behind a reverse proxy that rewrites `Host`, or when
--- the device reached the server by IP while the proxy answers by name, those
--- absolute links can point somewhere the device cannot reach. Every href is
--- therefore re-based onto the URL the user configured, which is by definition
--- reachable: this request got here.
function Url.rebase(base, href)
    if type(href) ~= "string" or href == "" then return nil end
    if type(base) ~= "string" or base == "" then return nil end
    local origin = Url.origin(href)
    if origin then
        local suffix = href:sub(#origin + 1)
        if suffix == "" then suffix = "/" end
        return base .. suffix
    end
    if href:sub(1, 1) == "/" then
        return base .. href
    end
    return base .. "/" .. href
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
--- Stump authenticates kosync by the API key in the path, so the key is part
--- of the base URL rather than a header.
function Url.kosync(base, api_key)
    if type(api_key) ~= "string" or api_key == "" then return nil end
    return base .. "/koreader/" .. api_key
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
