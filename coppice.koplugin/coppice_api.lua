--[[--
HTTP client for Coppice REST, GraphQL reads, and authenticated file/image transfer.

Pairing is unauthenticated and is the only onboarding path. The server returns
an API key for OPDS, GraphQL catalog reads, downloads and KOReader progress
plus a separate liseur device token for annotations/read state. Neither secret
is created or stored by this plugin until the user approves the six-digit code.

After pairing:

| Surface                | Credential                              |
| ---------------------- | --------------------------------------- |
| `/opds/v2.0/...`       | Basic user:api_key                      |
| `/api/v2/...`          | Bearer api_key                          |
| `/koreader/{api_key}`  | the API key in the path                  |
| `/v1/...`              | Bearer liseur device token              |
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local mime = require("mime")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")

-- `socket.http.request` only understands `https://` once LuaSec is loaded.
-- `socketutil` already requires it; doing it here keeps the dependency
-- visible instead of load-order luck.
pcall(require, "ssl.https")

local Url = require("coppice_url")
local Settings = require("coppice_settings")

local Api = {}
Api.__index = Api

local MAX_REDIRECTS = 4
local MAX_JSON_BYTES = 8 * 1024 * 1024
local ANNOTATION_CAPABILITIES = "annotation-color-drawer-v1"

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
        return nil, "invalid_json"
    end
    return scrubNulls(decoded) or {}
end

local function basicHeader(username, secret)
    return "Basic " .. mime.b64(tostring(username) .. ":" .. tostring(secret))
end

function Api.new(opts)
    opts = opts or {}
    return setmetatable({
        base = Url.normalizeBase(opts.base),
        username = Settings.text(opts.username),
        api_key = Settings.credential(opts.api_key),
        device_id = Settings.text(opts.device_id),
        device_name = Settings.text(opts.device_name),
        liseur_secret = Settings.credential(opts.liseur_secret),
    }, Api)
end

function Api:isConfigured()
    return self.base ~= nil
        and self.username ~= nil
        and self.api_key ~= nil
        and self.liseur_secret ~= nil
end

--- OPDS uses Basic only as a transport wrapper around the API key.
function Api:opdsAuthHeader()
    if not self.username or self.username == "" then return nil end
    if self.api_key and self.api_key ~= "" then
        return basicHeader(self.username, self.api_key)
    end
    return nil
end

--- The credential `/api/v2` gets: a Bearer API key from pairing.
function Api:apiAuthHeaders()
    if self.api_key and self.api_key ~= "" then
        return { ["Authorization"] = "Bearer " .. self.api_key }
    end
    return {}
end

--- One blocking request.
---
--- Returns `decoded_body, nil, code` on 2xx; `nil, err, code` otherwise.
--- HTTP response bodies and transport details are not exposed to UI callers.
function Api:request(spec)
    if type(spec) ~= "table" or not Url.sameOrigin(self.base, spec.url) then
        return nil, "invalid_url"
    end

    local sink_parts = {}
    local raw_size, oversized = 0, false
    local function boundedSink(chunk, sink_err)
        if chunk then
            raw_size = raw_size + #chunk
            if raw_size > MAX_JSON_BYTES then
                oversized = true
                return nil, "response_too_large"
            end
            sink_parts[#sink_parts + 1] = chunk
        elseif sink_err then
            return nil, sink_err
        end
        return 1
    end

    local headers = {
        ["accept"] = "application/json",
    }
    for key, value in pairs(type(spec.headers) == "table" and spec.headers or {}) do
        headers[key] = value
    end

    local request = {
        url = spec.url,
        method = spec.method or "GET",
        sink = boundedSink,
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
    local request_ok, code, response_headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()

    if oversized then return nil, "response_too_large", code end
    if not request_ok then
        return nil, tostring(code or "network_error")
    end
    if type(code) ~= "number" then
        return nil, tostring(status or code or "network_error")
    end
    if code < 200 or code >= 300 then
        local error_body
        if spec.capture_error_body then
            error_body = decode(sink_parts)
        end
        return nil, tostring(status or code), code, error_body
    end

    local body, decode_err = decode(sink_parts)
    if decode_err then return nil, decode_err, code end
    return body or {}, nil, code
end


-- --------------------------------------------------------------- pairing

--- Starts the unauthenticated five-minute device pairing window.
---
--- The response contains a one-time six-digit code and a poll nonce. Both are
--- kept only in settings while pending; the nonce is never sent anywhere but
--- the matching status URL.
function Api:pairingStart(name)
    local device_name = Settings.text(name) or "KOReader"
    local body, err, code = self:request({
        url = Url.api(self.base, "/devices/pair/start"),
        method = "POST",
        json = { kind = "coppice", name = device_name },
    })
    if not body then return nil, err, code end
    if type(body) ~= "table"
        or not Settings.credential(body.pairing_id)
        or type(body.code) ~= "string" or not body.code:match("^%d%d%d%d%d%d$")
        or not Settings.credential(body.nonce)
        or not Settings.text(body.expires_at, 64)
    then
        return nil, "invalid_pairing_start", code
    end
    return body, nil, code
end

--- Polls an existing pairing using its nonce. The nonce is included in the
--- query because the server deliberately treats it as a proof of possession.
function Api:pairingStatus(pairing_id, nonce)
    if not Settings.credential(pairing_id)
        or not Settings.credential(nonce)
    then
        return nil, "invalid_pairing", nil
    end
    local body, err, code = self:request({
        url = Url.api(self.base,
            "/devices/pair/" .. Url.escape(pairing_id) .. "/status",
            { nonce = nonce }),
    })
    if not body then return nil, err, code end
    if type(body) ~= "table"
        or type(body.status) ~= "string"
        or not ({ pending = true, approved = true, denied = true, expired = true })[body.status]
    then
        return nil, "invalid_pairing_status", code
    end
    return body, nil, code
end

-- ---------------------------------------------------------------- OPDS 2.0

function Api:opdsGet(url)
    local auth = self:opdsAuthHeader()
    if not auth then return nil, "no_credentials" end
    local body, err, code = self:request({
        url = url,
        headers = { ["Authorization"] = auth },
    })
    if not body then return nil, err, code end
    if type(body) ~= "table" then return nil, "invalid_response", code end
    return body, nil, code
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

function Api:apiGet(path, params)
    local body, err, code, error_body = self:request({
        url = Url.api(self.base, path, params),
        headers = self:apiAuthHeaders(),
    })
    return body, err, code, error_body
end

--- `GET /api/v2/reading/continue` — the continue-reading dashboard.
function Api:continueReading(limit)
    local body, err, code = self:apiGet("/reading/continue", { limit = limit })
    if not body then return nil, err, code end
    if type(body) ~= "table" or type(body.items) ~= "table" then
        return nil, "invalid_response", code
    end
    return body.items, nil, code
end

--- Executes a native Coppice GraphQL read using the paired device API key.
--- GraphQL can return HTTP 200 with resolver errors, so only complete data
--- envelopes are exposed to catalog callers.
function Api:graphql(query, variables)
    if type(query) ~= "string" or query == "" then
        return nil, "invalid_query"
    end
    local body, err, code = self:request({
        url = Url.rebase(self.base, "/api/graphql"),
        method = "POST",
        headers = self:apiAuthHeaders(),
        json = { query = query, variables = variables or {} },
    })
    if not body then return nil, err, code end
    if type(body.errors) == "table" and #body.errors > 0 then
        return nil, "graphql_error", code
    end
    if type(body.data) ~= "table" then
        return nil, "invalid_response", code
    end
    return body.data, nil, code
end

--- Streams an authenticated same-origin image to a cache file.
function Api:downloadAsset(url, target_path)
    return self:downloadTo(url, target_path, self:apiAuthHeaders())
end

-- --------------------------------------------------------------- downloads

--- Streams a URL to `target_path` through an exclusive same-directory
--- temporary file, then atomically replaces the destination on success.
function Api:downloadTo(url, target_path, auth_headers)
    if type(target_path) ~= "string" or target_path == "" then
        return nil, "no_target"
    end
    local current_url = Url.rebase(self.base, url)
    if not current_url then return nil, "invalid_url" end

    local function open_temp()
        for attempt = 1, 16 do
            local suffix = table.concat({
                tostring(os.time()),
                tostring(math.random(1, 2147483646)),
                tostring(attempt),
            }, "-")
            local candidate = target_path .. ".coppice-" .. suffix .. ".part"
            local file = io.open(candidate, "wbx")
            if file then return file, candidate end
        end
        return nil, nil, "cannot_create_temp"
    end

    local out, partial, io_err = open_temp()
    if not out then return nil, io_err or "cannot_open_target" end

    local sink_failure
    local stream_complete = false
    local transfer_started = os.time()
    local transfer_timeout = socketutil.FILE_TOTAL_TIMEOUT or 60
    local function close_out()
        if not out then return true end
        local file = out
        out = nil
        local ok, close_err = file:close()
        if not ok then
            sink_failure = close_err or "file_close_failed"
            return nil, sink_failure
        end
        return true
    end
    local function file_sink(chunk, err)
        if not chunk then
            if err then sink_failure = err end
            local ok, close_err = close_out()
            if not ok then return nil, close_err end
            if err then return nil, err end
            stream_complete = true
            return 1
        end
        if os.time() - transfer_started > transfer_timeout then
            sink_failure = socketutil.SINK_TIMEOUT_CODE or "timeout"
            close_out()
            return nil, sink_failure
        end
        local ok, write_err = out:write(chunk)
        if not ok then
            sink_failure = write_err or "file_write_failed"
            close_out()
            return nil, sink_failure
        end
        return 1
    end

    local headers = {}
    for key, value in pairs(auth_headers or {}) do headers[key] = value end

    local code, response_headers, status
    local redirects = 0
    while true do
        stream_complete = false
        socketutil:set_timeout(
            socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local request_ok
        request_ok, code, response_headers, status = pcall(function()
            return socket.skip(1, http.request({
                url = current_url,
                method = "GET",
                sink = file_sink,
                headers = headers,
            }))
        end)
        socketutil:reset_timeout()

        if not request_ok then break end
        if type(code) == "number" and code >= 300 and code < 400
                and redirects < MAX_REDIRECTS then
            local location = response_headers
                and (response_headers["location"] or response_headers["Location"])
            if not location or sink_failure then break end
            local next_url = Url.rebase(self.base, location)
            if not next_url then
                sink_failure = "invalid_redirect"
                break
            end
            os.remove(partial)
            out, partial, io_err = open_temp()
            if not out then
                os.remove(partial)
                return nil, io_err or "cannot_reopen_target"
            end
            current_url = next_url
            redirects = redirects + 1
        else
            break
        end
    end

    local close_ok, close_err = close_out()
    if not close_ok then sink_failure = close_err end
    if type(code) ~= "number" then
        os.remove(partial)
        return nil, sink_failure or tostring(status or code or "network_error")
    end
    if code < 200 or code >= 300 then
        os.remove(partial)
        return nil, tostring(status or code), code
    end
    if sink_failure or not stream_complete then
        os.remove(partial)
        return nil, sink_failure or "incomplete_download"
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
--- Coppice ignores the kosync username and digest entirely (KOReader sends an MD5
--- of the reusable secret, which cannot be checked against a bcrypt hash); the key in
--- the path is the credential.
function Api:kosyncAuth()
    local url = Url.kosyncAuth(self.base, self.api_key)
    if not url then return nil, "no_api_key" end
    local body, err, code = self:request({ url = url })
    if not body then return nil, err, code end
    if type(body) ~= "table" or body.authorized ~= "OK" then
        return nil, "invalid_response", code
    end
    return body, nil, code
end

--- `PUT /koreader/{key}/syncs/progress`.
---
--- `progress` is a *string*: a page number for a paged document, a crengine
--- DOM x-pointer for a reflowable one. `percentage` is `0..=1`. Both fields
--- plus `device` and `device_id` are required by the server DTO
--- (`coppice_koreader::PutProgressInput`).
function Api:kosyncPush(document, progress, percentage)
    local url = Url.kosyncPutProgress(self.base, self.api_key)
    if not url then return nil, "no_api_key" end
    if type(document) ~= "string" or document == "" then
        return nil, "no_document_hash"
    end
    if progress == nil then return nil, "no_progress" end
    if type(percentage) ~= "number" or percentage ~= percentage
            or percentage < 0 or percentage > 1 then
        return nil, "invalid_percentage"
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
    local body, err, code = self:request({
        url = url,
        block_timeout = 5,
        total_timeout = 15,
    })
    if not body then return nil, err, code end
    if type(body) ~= "table" or type(body.document) ~= "string" then
        return nil, "invalid_response", code
    end
    return body, nil, code
end

-- ------------------------------------------------------------ liseur-sync

function Api:liseurDescribeToken(secret)
    local auth = Settings.credential(secret)
    if not auth then return nil, "no_secret" end
    local body, err, code = self:request({
        url = Url.liseur(self.base, "/token"),
        headers = { ["Authorization"] = "Bearer " .. auth },
    })
    if not body then return nil, err, code end
    if type(body) ~= "table" then return nil, "invalid_response", code end
    return body, nil, code
end


--- `POST /v1/books/{book_id}/resolve` -> the user's `work_id` for that book.
---
--- Returns `work_id, response_body` or `nil, err, code`. Raw server error
--- bodies are never returned to UI callers.
function Api:liseurResolveWork(secret, book_id)
    local auth = Settings.credential(secret)
    if not auth then return nil, "no_secret" end
    local body, err, code = self:request({
        url = Url.liseur(self.base, "/books/" .. Url.escape(book_id) .. "/resolve"),
        method = "POST",
        headers = { ["Authorization"] = "Bearer " .. auth },
        json = {},
    })
    if not body then return nil, err, code end
    if type(body) ~= "table" then return nil, "invalid_response", code end
    if type(body.work_id) ~= "string" or body.work_id == "" then
        return nil, "no_work_id", code
    end
    return body.work_id, body, nil, code
end

--- `POST /v1/annotations` -> a per-item result list.
---
--- The batch is not atomic: each item comes back `applied`, `duplicate`,
--- `conflict` or `invalid`, and a `conflict` carries the server's current copy
--- so the caller can retry from the new revision.
function Api:liseurPushAnnotations(secret, annotations)
    local auth = Settings.credential(secret)
    if not auth then return nil, "no_secret" end
    local body, err, code = self:request({
        url = Url.liseur(self.base, "/annotations"),
        method = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. auth,
            ["X-Liseur-Annotation-Capabilities"] = ANNOTATION_CAPABILITIES,
        },
        json = { annotations = annotations },
    })
    if not body then return nil, err, code end
    if type(body) ~= "table" or type(body.results) ~= "table" then
        return nil, "invalid_response", code
    end
    return body, nil, code
end

--- `GET /v1/works/{work_id}/annotations` -> live records and optional tombstones.
function Api:liseurWorkAnnotations(secret, work_id, include_deleted)
    local auth = Settings.credential(secret)
    if not auth then return nil, "no_secret" end
    local body, err, code = self:request({
        url = Url.liseur(self.base,
            "/works/" .. Url.escape(work_id) .. "/annotations",
            { include_deleted = include_deleted == true }),
        headers = {
            ["Authorization"] = "Bearer " .. auth,
            ["X-Liseur-Annotation-Capabilities"] = ANNOTATION_CAPABILITIES,
        },
    })
    if not body then return nil, err, code end
    if type(body) ~= "table" or type(body.annotations) ~= "table" then
        return nil, "invalid_response", code
    end
    return body, nil, code
end

--- `DELETE /v1/annotations/{id}?rev=N` -> CAS delete or canonical conflict row.
function Api:liseurDeleteAnnotation(secret, id, revision)
    local auth = Settings.credential(secret)
    if not auth then return nil, "no_secret" end
    if type(id) ~= "string" or id == "" or tonumber(revision) == nil then
        return nil, "invalid_annotation"
    end
    local body, err, code, error_body = self:request({
        url = Url.liseur(self.base, "/annotations/" .. Url.escape(id),
            { rev = tonumber(revision) }),
        method = "DELETE",
        headers = {
            ["Authorization"] = "Bearer " .. auth,
            ["X-Liseur-Annotation-Capabilities"] = ANNOTATION_CAPABILITIES,
        },
        capture_error_body = true,
    })
    if not body then
        local server = type(error_body) == "table" and error_body.server or nil
        return nil, err, code, server
    end
    if type(body) ~= "table" or body.id ~= id or tonumber(body.rev) == nil then
        return nil, "invalid_response", code
    end
    return body, nil, code
end

return Api
