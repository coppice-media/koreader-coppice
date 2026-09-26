--[[--
Bidirectional annotation synchronization and persisted per-book queue logic.

The module's state transitions are pure where possible; device services are
injected so revision, retry, conflict, and anchoring behavior is host-testable.
]]

local Annotations = require("coppice_annotations")

local Sync = {}
Sync.__index = Sync
local MAX_SEARCH_HITS = 2048

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function map(value)
    return type(value) == "table" and value or {}
end

function Sync.bookKey(book_id, document_hash)
    return tostring(book_id or "") .. "\30" .. tostring(document_hash or "")
end

function Sync.newState(saved)
    saved = type(saved) == "table" and saved or {}
    return {
        work_id = saved.work_id,
        book_id = saved.book_id,
        document_hash = saved.document_hash,
        revisions = copy(map(saved.revisions)),
        id_map = copy(map(saved.id_map)),
        managed = copy(map(saved.managed)),
        queue = copy(map(saved.queue)),
        remote_notes = copy(map(saved.remote_notes)),
        tombstones = copy(map(saved.tombstones)),
        snapshot = copy(map(saved.snapshot)),
    }
end

function Sync.exportState(state)
    return copy(state or Sync.newState())
end
function Sync.copy(value)
    return copy(value)
end

function Sync.queueSnapshot(state, items, book_id, document_hash)
    state.snapshot = copy(items or {})
    state.book_id = book_id
    state.document_hash = document_hash
    return state
end

function Sync.loadState(doc_settings)
    local saved = doc_settings and doc_settings:readSetting(
        "coppice_annotation_sync")
    local state = Sync.newState(saved)
    if doc_settings then
        if next(state.revisions) == nil then
            state.revisions = copy(map(doc_settings:readSetting(
                "coppice_annotation_revs")))
        end
        for id, revision in pairs(state.revisions) do
            if not (type(revision) == "table" and revision.deleted)
                    and not state.managed[id] and not state.remote_notes[id] then
                state.managed[id] = true
            end
        end
    end
    return state
end

function Sync.saveState(doc_settings, state)
    if not doc_settings then return end
    doc_settings:saveSetting("coppice_annotation_sync",
        Sync.exportState(state))
    doc_settings:saveSetting("coppice_annotation_revs", state.revisions)
    doc_settings:flush()
end

local function itemId(item, state, options)
    if type(item) ~= "table" then return nil end
    if type(item.coppice_id) == "string" and item.coppice_id ~= "" then
        return item.coppice_id
    end
    local local_id = Annotations.localId(item, options.document_hash, options.digest)
    return local_id and state.id_map[local_id] or local_id
end

function Sync.currentItem(state, id, items, options)
    for _unused, item in ipairs(items or {}) do
        if itemId(item, state, options) == id then return item end
    end
end

local function inputSignature(input, digest)
    return Annotations.signature(input, digest)
end

--- Recompute idempotent pending actions from the current local annotation set.
function Sync.plan(items, state, options)
    state = state or Sync.newState()
    options = options or {}
    state.revisions = map(state.revisions)
    state.id_map = map(state.id_map)
    state.managed = map(state.managed)
    state.queue = map(state.queue)
    state.remote_notes = map(state.remote_notes)

    local present = {}
    for _unused, item in ipairs(items or {}) do
        local id = itemId(item, state, options)
        if id then present[id] = item end
    end

    local inputs, skipped = Annotations.batch(items or {}, {
        work_id = options.work_id,
        edition_sha = options.edition_sha,
        document_hash = options.document_hash,
        page_count = options.page_count,
        digest = options.digest,
        revisions = state.revisions,
        id_map = state.id_map,
        now = options.now,
    })
    local valid_inputs = {}
    for _unused, input in ipairs(inputs) do valid_inputs[input.id] = true end
    for id in pairs(present) do
        if not valid_inputs[id] then state.queue[id] = nil end
    end
    local queued = {}
    for _unused, input in ipairs(inputs) do
        local item = present[input.id]
        local revision = state.revisions[input.id]
        if type(revision) == "table" and revision.deleted then
            local recreated = Annotations.recreatedId(
                input.id, input.client_ts, options.digest)
            if recreated then
                local local_id = item and Annotations.localId(item,
                    options.document_hash, options.digest)
                if item then item.coppice_id = recreated end
                if local_id then state.id_map[local_id] = recreated end
                state.queue[input.id] = nil
                state.managed[input.id] = nil
                state.revisions[recreated] = nil
                input.id = recreated
                input.base_rev = 0
                present[input.id] = item
                revision = nil
            end
        end
        local signature = inputSignature(input, options.digest)
        local id = input.id
        if id and signature then
            state.managed[id] = true
            local local_id = item and Annotations.localId(item,
                options.document_hash, options.digest)
            if local_id then state.id_map[local_id] = id end
            local old = state.revisions[id]
            if type(old) == "table" and old.signature == signature then
                state.queue[id] = nil
            else
                state.queue[id] = {
                    op = "upsert",
                    input = copy(input),
                    signature = signature,
                    client_ts = input.client_ts,
                }
                queued[id] = true
            end
        end
    end

    local now = Annotations.clientTs(nil, options.now)
    for id in pairs(state.managed) do
        if not present[id] and not state.remote_notes[id] then
            local revision = state.revisions[id]
            if type(revision) == "table" and not revision.deleted
                    and tonumber(revision.rev) then
                local current = state.queue[id]
                if not current or current.op ~= "delete" then
                    state.queue[id] = {
                        op = "delete",
                        id = id,
                        rev = tonumber(revision.rev),
                        client_ts = now,
                    }
                end
                queued[id] = true
            elseif not revision or revision.deleted then
                state.queue[id] = nil
                state.managed[id] = nil
            end
        end
    end
    return inputs, skipped, queued
end

--- Resolve a revision conflict using client timestamps, not arrival order.
function Sync.resolveConflict(action, server)
    if type(action) ~= "table" or type(server) ~= "table" then
        return "unresolved"
    end
    if server.deleted then
        if action.op == "delete" then return "deleted" end
        if Annotations.timestampAfter(action.client_ts, server.deleted_at) then
            return "recreate"
        end
        return "server-wins"
    end
    local remote_ts = server.client_ts
    if Annotations.timestampAfter(action.client_ts, remote_ts) then
        return "retry"
    end
    return "server-wins"
end

function Sync.accept(state, id, revision, signature, client_ts)
    state.revisions[id] = {
        rev = tonumber(revision),
        signature = signature,
        client_ts = client_ts,
    }
    state.queue[id] = nil
    state.managed[id] = true
end

local function serverSignature(record, digest)
    local input = Annotations.remoteInput(record)
    return input and inputSignature(input, digest) or nil
end

local function getWorkRecord(api, secret, work_id, id)
    local response, err, code = api:liseurWorkAnnotations(secret, work_id, true)
    if not response then return nil, err, code end
    for _unused, record in ipairs(response.annotations) do
        if record.id == id then return record end
    end
end

local function handleConflict(state, action, record, options)
    local result = Sync.resolveConflict(action, record)
    if result == "retry" then
        local revision = tonumber(record.rev)
        if not revision then return "unresolved" end
        if action.op == "upsert" then
            action.input.base_rev = revision
        else
            action.rev = revision
        end
        state.queue[action.id or action.input.id] = action
        return "retry"
    elseif result == "recreate" then
        local previous_id = action.input.id
        local new_id = Annotations.recreatedId(previous_id,
            action.client_ts, options.digest)
        if not new_id then return "unresolved" end
        action.input.id = new_id
        action.input.base_rev = 0
        action.id = new_id
        action.signature = inputSignature(action.input, options.digest)
        state.queue[previous_id] = nil
        state.queue[new_id] = action
        state.managed[previous_id] = nil
        state.managed[new_id] = true
        state.revisions[previous_id] = {
            rev = tonumber(record.rev), deleted = true,
            deleted_at = record.deleted_at,
        }
        state.revisions[new_id] = nil
        if options.onRecreated then options.onRecreated(previous_id, new_id) end
        return "recreate"
    elseif result == "deleted" then
        local id = action.id or action.input.id
        state.queue[id] = nil
        state.managed[id] = nil
        state.revisions[id] = {
            rev = tonumber(record.rev), deleted = true,
            deleted_at = record.deleted_at,
        }
        state.tombstones[id] = copy(record)
        return "deleted"
    elseif result == "server-wins" then
        local id = action.id or action.input.id
        state.queue[id] = nil
        state.revisions[id] = {
            rev = tonumber(record.rev),
            signature = serverSignature(record, options.digest),
            client_ts = record.client_ts,
        }
        state.managed[id] = true
        return "server-wins"
    end
    return "unresolved"
end

local function pendingActions(state, op)
    local actions = {}
    for _unused, action in pairs(state.queue) do
        if action.op == op then table.insert(actions, action) end
    end
    table.sort(actions, function(left, right)
        local left_id = left.id or left.input and left.input.id or ""
        local right_id = right.id or right.input and right.input.id or ""
        return left_id < right_id
    end)
    return actions
end

--- Push persisted upserts and deletes; failed actions remain queued.
function Sync.drain(api, secret, state, options)
    options = options or {}
    local work_id = options.work_id or state.work_id
    local result = { applied = 0, duplicate = 0, deleted = 0,
        conflicts = 0, invalid = 0, failed = nil }
    local deferred_pull = false

    local retry_inputs = {}
    local upserts = pendingActions(state, "upsert")
    for _unused, action in ipairs(upserts) do table.insert(retry_inputs, action.input) end
    for pass = 1, 2 do
        if #retry_inputs == 0 then break end
        local batch_inputs = retry_inputs
        retry_inputs = {}
        for _unused, chunk in ipairs(Annotations.chunk(batch_inputs)) do
            local body, err, code = api:liseurPushAnnotations(secret, chunk)
            if not body then
                result.failed = { error = err, code = code }
                return false, result
            end
            for _unused, response in ipairs(body.results) do
                local id = response.id
                local action = state.queue[id]
                if response.status == "applied" or response.status == "duplicate" then
                    if action and action.op == "upsert" then
                        Sync.accept(state, id, response.rev, action.signature,
                            action.client_ts)
                    end
                    result[response.status] = result[response.status] + 1
                elseif response.status == "conflict" then
                    result.conflicts = result.conflicts + 1
                    local server = response.server
                    if not server and id then
                        server = getWorkRecord(api, secret, work_id, id)
                    end
                    if action and server then
                        local outcome = handleConflict(state, action, server, options)
                        if outcome == "retry" and pass == 1 then
                            table.insert(retry_inputs, action.input)
                        elseif outcome == "server-wins" then
                            deferred_pull = true
                        elseif outcome == "recreate" then
                            table.insert(retry_inputs, action.input)
                        elseif outcome == "unresolved" then
                            result.failed = { error = "unresolved_conflict", id = id }
                        end
                    else
                        result.failed = { error = "missing_conflict_record", id = id }
                    end
                else
                    result.invalid = result.invalid + 1
                    result.failed = { error = response.reason or response.status,
                        id = id }
                end
            end
        end
    end

    local retry_deletes = {}
    for _unused, action in ipairs(pendingActions(state, "delete")) do
        local id = action.id
        local response, err, code, server =
            api:liseurDeleteAnnotation(secret, id, action.rev)
        if response then
            state.revisions[id] = {
                rev = tonumber(response.rev), deleted = true,
            }
            state.tombstones[id] = { id = id, rev = tonumber(response.rev),
                deleted = true, seq = tonumber(response.seq) }
            state.queue[id] = nil
            state.managed[id] = nil
            for local_id, remote_id in pairs(state.id_map) do
                if remote_id == id then state.id_map[local_id] = nil end
            end
            result.deleted = result.deleted + 1
        elseif tonumber(code) == 409 then
            result.conflicts = result.conflicts + 1
            server = server or getWorkRecord(api, secret, work_id, id)
            if not server then
                result.failed = { error = err or "missing_conflict_record", id = id }
            else
                local outcome = handleConflict(state, action, server, options)
                if outcome == "retry" then
                    if #retry_deletes == 0 then table.insert(retry_deletes, action) end
                    deferred_pull = true
                elseif outcome == "deleted" then
                    result.deleted = result.deleted + 1
                elseif outcome == "server-wins" then
                    deferred_pull = true
                else
                    result.failed = { error = "unresolved_conflict", id = id }
                end
            end
        else
            result.failed = { error = err, code = code, id = id }
        end
    end

    for _unused, action in ipairs(retry_deletes) do
        local response, err, code, server =
            api:liseurDeleteAnnotation(secret, action.id, action.rev)
        if response then
            state.revisions[action.id] = {
                rev = tonumber(response.rev), deleted = true,
            }
            state.tombstones[action.id] = { id = action.id,
                rev = tonumber(response.rev), deleted = true,
                seq = tonumber(response.seq) }
            state.queue[action.id] = nil
            for local_id, remote_id in pairs(state.id_map) do
                if remote_id == action.id then state.id_map[local_id] = nil end
            end
            state.managed[action.id] = nil
            result.deleted = result.deleted + 1
        elseif tonumber(code) == 409 then
            local current = server or getWorkRecord(api, secret, work_id, action.id)
            if current then handleConflict(state, action, current, options) end
            result.failed = { error = err or "revision_conflict", id = action.id }
        else
            result.failed = { error = err, code = code, id = action.id }
        end
    end
    result.needs_pull = deferred_pull
    return result.failed == nil, result
end

local function normalizedHref(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("[?#].*$", ""):gsub("^%./", "")
    return value ~= "" and value or nil
end

local function tocIdentity(ui, document, xpointer)
    local page
    if document and type(document.getPageFromXPointer) == "function"
            and type(xpointer) == "string" then
        local ok, value = pcall(document.getPageFromXPointer, document, xpointer)
        if ok then page = value end
    end
    local toc = ui and ui.toc
    local title, href
    if toc and page and type(toc.getTocTitleByPage) == "function" then
        local ok, value = pcall(toc.getTocTitleByPage, toc, page)
        if ok then title = value end
        local index
        if type(toc.getTocIndexByPage) == "function" then
            local index_ok, index_value = pcall(toc.getTocIndexByPage, toc,
                page, toc.toc_chapter_title_bind_to_ticks)
            if index_ok then index = index_value end
        end
        local entry = index and toc.toc and toc.toc[index]
        if type(entry) == "table" then
            href = entry.href or entry.url or entry.file or entry.path or entry.id
        end
    end
    return title, normalizedHref(href)
end

local function readiumHints(record)
    local locator = type(record.locator) == "table" and record.locator or {}
    local locations = type(locator.locations) == "table" and locator.locations or {}
    local excerpt = record.excerpt
    local text = type(locator.text) == "table" and locator.text or {}
    excerpt = excerpt or text.highlight
    local href = locator.href or locations.href
    local chapter = locator.chapter or locator.chapterTitle or locator.title
        or locations.chapter
    if type(excerpt) ~= "string" or excerpt == ""
            or (not href and not chapter) then
        return nil
    end
    return { href = normalizedHref(href), chapter = chapter,
        text = { before = text.before, after = text.after } }, excerpt
end

local function searchAnchor(record, options)
    local hints, excerpt = readiumHints(record)
    if not hints then return nil, "missing-search-location" end
    local document = options.document
    if not document or type(document.findAllText) ~= "function" then
        return nil, "search-unavailable"
    end
    local ok, hits = pcall(document.findAllText, document, excerpt, true, 5,
        MAX_SEARCH_HITS, false, 0)
    if not ok or type(hits) ~= "table" then return nil, "search-failed" end
    if #hits >= MAX_SEARCH_HITS then return nil, "too-many-matches" end
    local candidates = {}
    for _unused, hit in ipairs(hits) do
        if hit.start ~= nil and hit["end"] ~= nil then
            local chapter, href = tocIdentity(options.ui, document, hit.start)
            local matching_text = table.concat({ hit.matched_word_prefix or "",
                hit.matched_text or "", hit.matched_word_suffix or "" })
            table.insert(candidates, {
                start = hit.start,
                finish = hit["end"],
                text = matching_text,
                before = hit.prev_text,
                after = hit.next_text,
                chapter = chapter,
                href = href,
            })
        end
    end
    return Annotations.anchorCandidates(candidates, hints, excerpt)
end

local function nativeAnchor(record, options)
    local locator = record.locator
    if type(locator) ~= "table"
            or locator.format ~= Annotations.LOCATOR_FORMAT
            or locator.version ~= Annotations.LOCATOR_VERSION then
        return nil, "not-native"
    end
    if locator.document and options.document_hash
            and locator.document ~= options.document_hash then
        return nil, "different-document"
    end
    local page = locator.page or locator.pos0
    if page == nil then return nil, "unanchored" end
    if type(page) == "string" and options.document
            and type(options.document.isXPointerInDocument) == "function" then
        local ok, valid = pcall(options.document.isXPointerInDocument,
            options.document, page)
        if not ok or valid ~= true then return nil, "invalid-xpointer" end
    end
    return { start = page, finish = locator.pos1,
        chapter = locator.chapter }
end

local function localClientTs(item, state, options)
    local input = Annotations.one(item, {
        work_id = options.work_id,
        edition_sha = options.edition_sha,
        document_hash = options.document_hash,
        page_count = options.page_count,
        digest = options.digest,
        revisions = state.revisions,
        id_map = state.id_map,
    })
    return input and input.client_ts
end

local function removeLocal(item, options)
    local items = options.items
    for index, current in ipairs(items) do
        if current == item then
            table.remove(items, index)
            if options.emit then
                options.emit({ item, index_modified = -index })
            end
            return true
        end
    end
    return false
end

local function putLocal(item, options, previous)
    if previous then removeLocal(previous, options) end
    local annotation = options.annotation
    local index
    if annotation and type(annotation.addItem) == "function" then
        index = annotation:addItem(item)
    else
        table.insert(options.items, item)
        index = #options.items
    end
    if options.emit then options.emit({ item, index_modified = index }) end
    return item
end

local function markRemoteRevision(record, state, options, item, use_local_signature)
    local signature = serverSignature(record, options.digest)
    if item then
        local input = Annotations.one(item, {
            work_id = options.work_id,
            edition_sha = options.edition_sha,
            document_hash = options.document_hash,
            page_count = options.page_count,
            digest = options.digest,
            revisions = state.revisions,
            id_map = state.id_map,
        })
        if use_local_signature then
            signature = inputSignature(input, options.digest) or signature
        end
        local local_id = Annotations.localId(item, options.document_hash,
            options.digest)
        if local_id then state.id_map[local_id] = record.id end
        state.managed[record.id] = true
    end
    state.revisions[record.id] = {
        rev = tonumber(record.rev),
        signature = signature,
        client_ts = record.client_ts,
    }
end

--- Reconcile a work snapshot with native annotations and tombstones.
function Sync.reconcile(records, state, options)
    options = options or {}
    state = state or Sync.newState()
    local live = {}
    local tombstones = {}
    for _unused, record in ipairs(records or {}) do
        if record.deleted then
            tombstones[record.id] = record
        elseif type(record.id) == "string" then
            live[record.id] = record
        end
    end
    local counts = { imported = 0, updated = 0, removed = 0, remote = 0 }

    for id, record in pairs(tombstones) do
        local item = Sync.currentItem(state, id, options.items, options)
        local local_ts = item and localClientTs(item, state, options)
        local local_newer = item
            and Annotations.timestampAfter(local_ts, record.deleted_at)
        if local_newer then
            local replacement = Annotations.recreatedId(id, local_ts,
                options.digest)
            if replacement then
                item.coppice_id = replacement
                local local_id = Annotations.localId(item,
                    options.document_hash, options.digest)
                if local_id then state.id_map[local_id] = replacement end
                state.managed[id] = nil
                state.managed[replacement] = true
                state.queue[id] = nil
                state.revisions[replacement] = nil
            end
        else
            if item then
                removeLocal(item, options)
                counts.removed = counts.removed + 1
            end
            for local_id, remote_id in pairs(state.id_map) do
                if remote_id == id then state.id_map[local_id] = nil end
            end
            state.managed[id] = nil
            state.queue[id] = nil
        end
        state.remote_notes[id] = nil
        state.tombstones[id] = copy(record)
        state.revisions[id] = {
            rev = tonumber(record.rev), deleted = true,
            deleted_at = record.deleted_at,
        }
    end

    for id, record in pairs(live) do
        local action = state.queue[id]
        local item = Sync.currentItem(state, id, options.items, options)
        if action and action.op == "delete" and not item
                and Annotations.timestampAfter(action.client_ts, record.client_ts) then
            state.revisions[id] = {
                rev = tonumber(record.rev),
                signature = serverSignature(record, options.digest),
                client_ts = record.client_ts,
            }
        else
            local local_ts = item and localClientTs(item, state, options)
            local local_input = item and Annotations.one(item, {
                work_id = options.work_id,
                edition_sha = options.edition_sha,
                document_hash = options.document_hash,
                page_count = options.page_count,
                digest = options.digest,
                revisions = state.revisions,
                id_map = state.id_map,
            })
            local local_signature = local_input
                and inputSignature(local_input, options.digest)
            local previous = state.revisions[id]
            local same_local = previous and previous.signature == local_signature
                and previous.client_ts == record.client_ts
            local use_server = not item or (not same_local
                and not Annotations.timestampAfter(local_ts, record.client_ts))
            if use_server then
                local position, reason = nativeAnchor(record, options)
                if reason == "not-native" then
                    position, reason = searchAnchor(record, options)
                end
                local imported, import_error = Annotations.fromRemote(record,
                    position, options.default_drawer)
                if imported then
                    putLocal(imported, options, item)
                    state.remote_notes[id] = nil
                    markRemoteRevision(record, state, options, imported, true)
                    if item then counts.updated = counts.updated + 1
                    else counts.imported = counts.imported + 1 end
                else
                    state.remote_notes[id] = {
                        record = copy(record),
                        reason = reason or import_error or "unanchorable",
                    }
                    state.revisions[id] = {
                        rev = tonumber(record.rev),
                        signature = serverSignature(record, options.digest),
                        client_ts = record.client_ts,
                    }
                    state.managed[id] = nil
                    counts.remote = counts.remote + 1
                end
            else
                markRemoteRevision(record, state, options, item, false)
            end
            if action and action.op == "delete"
                    and not Annotations.timestampAfter(action.client_ts,
                        record.client_ts) then
                state.queue[id] = nil
            end
        end
    end
    return counts
end

function Sync.new(options)
    options = options or {}
    local self = setmetatable({}, Sync)
    for key, value in pairs(options) do self[key] = value end
    self.state = Sync.newState(options.state)
    self.items = options.items or {}
    return self
end

--- Pull, reconcile, queue local changes, and drain pending writes.
function Sync:run(pull)
    local state = self.state
    local options = self
    local pull_counts
    if pull then
        local response, err, code = self.api:liseurWorkAnnotations(
            self.secret, self.work_id, true)
        if not response then
            return false, { failed = { error = err, code = code } }
        end
        pull_counts = Sync.reconcile(response.annotations, state, options)
    end
    local _unused, skipped = Sync.plan(self.items, state, options)
    local ok, result = Sync.drain(self.api, self.secret, state, options)
    result.skipped = skipped
    result.pull = pull_counts
    if result.needs_pull then
        local response, err, code = self.api:liseurWorkAnnotations(
            self.secret, self.work_id, true)
        if response then
            result.pull = Sync.reconcile(response.annotations, state, options)
            if not result.failed then
                Sync.plan(self.items, state, options)
                local retry_ok, retry = Sync.drain(
                    self.api, self.secret, state, options)
                result.applied = result.applied + retry.applied
                result.duplicate = result.duplicate + retry.duplicate
                result.deleted = result.deleted + retry.deleted
                result.conflicts = result.conflicts + retry.conflicts
                result.invalid = result.invalid + retry.invalid
                result.failed = retry.failed
                ok = retry_ok
            end
        elseif not result.failed then
            result.failed = { error = err, code = code }
            ok = false
        end
    end
    if self.persist then self.persist(state) end
    return ok, result
end

return Sync
