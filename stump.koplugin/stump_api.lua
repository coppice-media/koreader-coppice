--[[--
HTTP client for the four Stump surfaces.

Stump does not accept one credential everywhere, and pretending otherwise is
how a client ends up with mysterious 401s:

| Surface                | Accepts                                            |
| ---------------------- | -------------------------------------------------- |
| `/opds/v2.0/...`       | `Basic user:password` **or** `Basic user:api_key`   |
| `/api/v2/...`          | `Bearer <api_key>` or a `stump_session` cookie      |
| `/koreader/{api_key}`  | the key in the path; no header                      |
| `/v1/...`              | `Bearer <device secret>` minted by `/v1/login`      |

`Basic` is rejected outside `/opds` and the Komga compatibility paths
(`basic_auth_accepted` in `apps/server/src/middleware/auth.rs`), and there is
no `/opds/{api_key}/v2.0` route — only OPDS 1.2 has the key-in-path form. So
the API key is preferred as the Basic *password* for OPDS (it is the narrower
credential: a device key carries only the permissions it was granted), with
the account password as the fallback, and the same key becomes a Bearer token
on `/api/v2`.
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local mime = require("mime")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")

-- `socket.http.request` only understands `https://` once LuaSec is loaded.
-- `socketutil` already requires it; doing it here keeps the dependency
-- visible instead of load-order luck.
pcall(require, "ssl.https")

local Url = require("stump_url")

local Api = {}
Api.__index = Api

local MAX_REDIRECTS = 4
local MAX_JSON_BYTES = 8 * 1024 * 1024

--- JSON `null` decodes to a lightuserdata that is *truthy* in Lua; left alone
--- it leaks into settings files and every `if value then` test.
local function scrubNulls(value)
    if value == rapidjson.null then return nil end
    if type(value) == "table" then
        for key, item in pairs(value) do
            value[key] = scrubNulls(item)
        end
    end
    return value
end

local function decode(parts)
    local raw = table.concat(parts or {})
    if raw == "" then return {} end
    local ok, decoded = pcall(rapidjson.decode, raw)
    if not ok or decoded == nil then
        return nil, "invalid_json", raw
    end
    return scrubNulls(decoded) or {}
end

local function basicHeader(username, secret)
    return "Basic " .. mime.b64(tostring(username) .. ":" .. tostring(secret))
end

function Api.new(opts)
    opts = opts or {}
    return setmetatable({
        base = opts.base,
        username = opts.username,
        password = opts.password,
        api_key = opts.api_key,
        device_id = opts.device_id,
        device_name = opts.device_name,
        -- Minted lazily and cached in memory; the caller persists it.
        liseur_secret = opts.liseur_secret,
        session_cookie = nil,
    }, Api)
end

function Api:isConfigured()
    if not self.base then return false end
    if self.api_key and self.api_key ~= "" then return true end
    return (self.username or "") ~= "" and (self.password or "") ~= ""
end

--- The credential OPDS gets. The key is preferred; see the module comment.
function Api:opdsAuthHeader()
    if not self.username or self.username == "" then return nil end
    if self.api_key and self.api_key ~= "" then
        return basicHeader(self.username, self.api_key)
    end
    if self.password and self.password ~= "" then
        return basicHeader(self.username, self.password)
    end
    return nil
end

--- The credential `/api/v2` gets: a Bearer API key, or a session cookie the
--- plugin logged in for.
function Api:apiAuthHeaders()
    if self.api_key and self.api_key ~= "" then
        return { ["Authorization"] = "Bearer " .. self.api_key }
    end
    if self.session_cookie then
        return { ["Cookie"] = self.session_cookie }
    end
    return {}
end

--- One blocking request.
---
--- Returns `decoded_body, nil, code` on 2xx; `nil, err, code, decoded_error`
--- otherwise, where `err` is the HTTP status line for an HTTP error and a
--- transport string ("timeout", "closed", ...) for a socket failure.
function Api:request(spec)
    local sink_parts = {}
    local headers = {
        ["accept"] = "application/json",
    }
    for key, value in pairs(spec.headers or {}) do
        headers[key] = value
    end

    local request = {
        url = spec.url,
        method = spec.method or "GET",
        sink = ltn12.sink.table(sink_parts),
        headers = headers,
    }

    if spec.json ~= nil then
        local ok, body = pcall(rapidjson.encode, spec.json)
        if not ok or type(body) ~= "string" then
            return nil, "encode_failed"
        end
        request.source = ltn12.source.string(body)
        headers["content-type"] = "application/json"
        headers["content-length"] = tostring(#body)
    end

    socketutil:set_timeout(
        spec.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
        spec.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local code, response_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if type(code) ~= "number" then
        logger.warn("Stump: transport error", status or code, spec.url)
        return nil, tostring(status or code or "network_error")
    end

    if spec.capture_session and response_headers then
        local cookie = response_headers["set-cookie"] or response_headers["Set-Cookie"]
        local session = cookie and cookie:match("(stump_session=[^;]+)")
        if session then self.session_cookie = session end
    end

    local raw_size = 0
    for _, part in ipairs(sink_parts) do raw_size = raw_size + #part end
    if raw_size > MAX_JSON_BYTES then
        return nil, "response_too_large", code
    end

    local body, decode_err = decode(sink_parts)

    if code < 200 or code >= 300 then
        return nil, tostring(status or code), code, body
    end
    if decode_err then
        return nil, decode_err, code
    end
    return body or {}, nil, code
end

-- ---------------------------------------------------------------- OPDS 2.0

function Api:opdsGet(url)
    local auth = self:opdsAuthHeader()
    if not auth then return nil, "no_credentials" end
    return self:request({ url = url, headers = { ["Authorization"] = auth } })
end

function Api:opdsCatalog()
    return self:opdsGet(Url.opds(self.base, "/catalog"))
end

--- Feeds below the root are reached by following the `href`s the server put
--- in the previous feed (that is what OPDS navigation is), so there are no
--- per-feed wrappers here — only the two entry points a caller cannot be
--- handed a link to.

function Api:opdsSearch(query, page, page_size)
    return self:opdsGet(Url.opds(self.base, "/search",
        { query = query, page = page, page_size = page_size }))
end

-- --------------------------------------------------------------- /api/v2

--- Logs in with username/password and keeps the session cookie.
---
--- Only needed when no API key is configured: `/api/v2` rejects Basic, so
--- there is no header-only path for a password.
function Api:sessionLogin()
    if not self.username or not self.password or self.password == "" then
        return nil, "no_password"
    end
    local body, err, code = self:request({
        url = Url.api(self.base, "/auth/login"),
        method = "POST",
        json = { username = self.username, password = self.password },
        capture_session = true,
    })
    if not body then return nil, err, code end
    if not self.session_cookie then return nil, "no_session_cookie", code end
    return body
end

function Api:apiGet(path, params)
    local body, err, code, error_body = self:request({
        url = Url.api(self.base, path, params),
        headers = self:apiAuthHeaders(),
    })
    -- No key and no session yet (or an expired one): log in once and retry.
    if not body and code == 401 and (not self.api_key or self.api_key == "") then
        self.session_cookie = nil
        if self:sessionLogin() then
            return self:request({
                url = Url.api(self.base, path, params),
                headers = self:apiAuthHeaders(),
            })
        end
    end
    return body, err, code, error_body
end

--- `GET /api/v2/reading/continue` — the continue-reading dashboard.
function Api:continueReading(limit)
    local body, err, code = self:apiGet("/reading/continue", { limit = limit })
    if not body then return nil, err, code end
    return body.items or {}
end

-- --------------------------------------------------------------- downloads

--- Streams a URL to `target_path`.
---
--- Writes through `<target>.part` and renames, so an interrupted download
--- never leaves a truncated file that KOReader would then try to open.
function Api:downloadTo(url, target_path, auth_headers)
    local partial = target_path .. ".part"
    local out, io_err = io.open(partial, "wb")
    if not out then return nil, io_err or "cannot_open_target" end

    local headers = {}
    for key, value in pairs(auth_headers or {}) do headers[key] = value end

    local current_url, redirects = url, 0
    local code, response_headers, status
    while true do
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        code, response_headers, status = socket.skip(1, http.request({
            url = current_url,
            method = "GET",
            sink = socketutil.file_sink(out),
            headers = headers,
        }))
        socketutil:reset_timeout()

        if type(code) == "number" and code >= 300 and code < 400
                and redirects < MAX_REDIRECTS then
            local location = response_headers
                and (response_headers["location"] or response_headers["Location"])
            if not location then break end
            current_url = Url.rebase(self.base, location) or location
            redirects = redirects + 1
            -- `file_sink` closed the handle on the redirect body; start over.
            out = io.open(partial, "wb")
            if not out then
                os.remove(partial)
                return nil, "cannot_reopen_target"
            end
        else
            break
        end
    end

    if type(code) ~= "number" then
        os.remove(partial)
        return nil, tostring(status or code or "network_error")
    end
    if code < 200 or code >= 300 then
        os.remove(partial)
        return nil, tostring(status or code), code
    end

    local ok, rename_err = os.rename(partial, target_path)
    if not ok then
        os.remove(partial)
        return nil, rename_err or "cannot_rename"
    end
    return target_path
end

--- The book file. `/api/v2/media/{id}/file` is used rather than the OPDS
--- acquisition link so the download rides the same credential as the
--- dashboard; both serve the original bytes.
function Api:downloadBook(book_id, target_path)
    return self:downloadTo(
        Url.api(self.base, "/media/" .. Url.escape(book_id) .. "/file"),
        target_path,
        self:apiAuthHeaders())
end

-- ----------------------------------------------------------------- kosync

--- `GET /koreader/{key}/users/auth` -> `{"authorized":"OK"}`.
---
--- Stump ignores the kosync username/password entirely (KOReader sends an MD5
--- of the password, which cannot be checked against a bcrypt hash); the key in
--- the path is the credential.
function Api:kosyncAuth()
    local url = Url.kosyncAuth(self.base, self.api_key)
    if not url then return nil, "no_api_key" end
    return self:request({ url = url })
end

--- `PUT /koreader/{key}/syncs/progress`.
---
--- `progress` is a *string*: a page number for a paged document, a crengine
--- DOM x-pointer for a reflowable one. `percentage` is `0..=1`. Both fields
--- plus `device` and `device_id` are required by the server DTO
--- (`stump_koreader::PutProgressInput`).
function Api:kosyncPush(document, progress, percentage)
    local url = Url.kosyncPutProgress(self.base, self.api_key)
    if not url then return nil, "no_api_key" end
    if type(document) ~= "string" or document == "" then
        return nil, "no_document_hash"
    end
    return self:request({
        url = url,
        method = "PUT",
        json = {
            document = document,
            progress = tostring(progress),
            percentage = percentage,
            device = self.device_name or "KOReader",
            device_id = self.device_id or "koreader",
        },
        block_timeout = 5,
        total_timeout = 15,
    })
end

--- `GET /koreader/{key}/syncs/progress/{document}`.
function Api:kosyncPull(document)
    local url = Url.kosyncGetProgress(self.base, self.api_key, document)
    if not url then return nil, "no_api_key_or_document" end
    return self:request({ url = url, block_timeout = 5, total_timeout = 15 })
end

-- ------------------------------------------------------------ liseur-sync

--- `POST /v1/login` -> a one-hour token-management session bearer.
---
--- This lane needs the real password: the server bcrypt-verifies it
--- (`liseur_sync::storage::login`), so an API key does not stand in here.
function Api:liseurLogin()
    if not self.username or not self.password or self.password == "" then
        return nil, "no_password"
    end
    local body, err, code = self:request({
        url = Url.liseur(self.base, "/login"),
        method = "POST",
        json = { username = self.username, password = self.password },
    })
    if not body then return nil, err, code end
    if type(body.auth_token) ~= "string" then return nil, "no_auth_token", code end
    return body.auth_token
end

--- `POST /v1/tokens` -> a long-lived device secret, returned exactly once.
---
--- The login session can only mint and revoke; the sync and catalog lanes
--- need a device token carrying `sync` and `library-read`.
function Api:liseurMintToken(session_token, name)
    local body, err, code = self:request({
        url = Url.liseur(self.base, "/tokens"),
        method = "POST",
        headers = { ["Authorization"] = "Bearer " .. session_token },
        json = {
            name = name or (self.device_name or "KOReader"),
            scopes = { "sync", "library-read" },
        },
    })
    if not body then return nil, err, code end
    if type(body.secret) ~= "string" then return nil, "no_secret", code end
    return body.secret, body.device_id, body.token_id
end

--- `GET /v1/token` — confirms a stored secret is still live.
function Api:liseurDescribeToken(secret)
    return self:request({
        url = Url.liseur(self.base, "/token"),
        headers = { ["Authorization"] = "Bearer " .. secret },
    })
end

--- Returns a usable device secret, minting one if needed.
---
--- The second return value is `true` when a new secret was minted, so the
--- caller knows it has to persist it (it is never retrievable again).
function Api:liseurEnsureToken()
    if self.liseur_secret and self.liseur_secret ~= "" then
        if self:liseurDescribeToken(self.liseur_secret) then
            return self.liseur_secret, false
        end
        self.liseur_secret = nil
    end
    local session, err, code = self:liseurLogin()
    if not session then return nil, false, err, code end
    local secret, _, _ = self:liseurMintToken(session)
    if not secret then return nil, false, "mint_failed" end
    self.liseur_secret = secret
    return secret, true
end

--- `POST /v1/books/{book_id}/resolve` -> the user's `work_id` for that book.
---
--- Positions and annotations are keyed by a user-scoped Work, never by a
--- `media_id`, so this is the mandatory first step of the annotation lane.
---
--- Returns `work_id, response_body` or `nil, message`. The failure message
--- prefers the server's own `error` field, because the two failures a user
--- will actually hit both say something specific: a `409` "identifiers
--- resolve to multiple works" (two library copies claim the same identity)
--- and a `500` on a directory-backed book (the resolver digests the file, and
--- a multi-file audiobook has no single file to digest).
function Api:liseurResolveWork(secret, book_id)
    local body, err, code, error_body = self:request({
        url = Url.liseur(self.base, "/books/" .. Url.escape(book_id) .. "/resolve"),
        method = "POST",
        headers = { ["Authorization"] = "Bearer " .. secret },
        json = {},
    })
    if not body then
        local message = type(error_body) == "table" and error_body.error or err
        return nil, tostring(message or code)
    end
    if type(body.work_id) ~= "string" then return nil, "no_work_id" end
    return body.work_id, body
end

--- `POST /v1/annotations` -> a per-item result list.
---
--- The batch is not atomic: each item comes back `applied`, `duplicate`,
--- `conflict` or `invalid`, and a `conflict` carries the server's current copy
--- so the caller can retry from the new revision.
function Api:liseurPushAnnotations(secret, annotations)
    return self:request({
        url = Url.liseur(self.base, "/annotations"),
        method = "POST",
        headers = { ["Authorization"] = "Bearer " .. secret },
        json = { annotations = annotations },
    })
end

--- `GET /v1/works/{work_id}/annotations` -> the live set (no tombstones).
function Api:liseurWorkAnnotations(secret, work_id)
    return self:request({
        url = Url.liseur(self.base,
            "/works/" .. Url.escape(work_id) .. "/annotations"),
        headers = { ["Authorization"] = "Bearer " .. secret },
    })
end

return Api
