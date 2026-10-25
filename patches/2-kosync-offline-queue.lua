--[[
Backports upstream KOReader's offline queue for Progress sync (kosync) to v2023.06.1,
from koreader/koreader#15324 and #16153 (2026).

In v2023.06.1, closing a book with automatic sync on calls NetworkMgr:goOnlineToRun(),
which blocks for up to 30 s until the device is online, even with no sync account.
On Android KOReader can't turn Wi-Fi on itself, so it always waits the full 30 s,
and Android reports KOReader as not responding.

With this patch:
- Closing a book never waits for the network. It pushes the position when online,
  queues it in settings/kosync_queue.lua when not, and does nothing without an account.
- Failed pushes (network or server errors, but not a rejected login) are queued too:
  one entry per book per day, kept for 4 weeks.
- The queue is sent oldest first on NetworkConnected (as upstream), and also after any
  successful push, because on Android the system manages Wi-Fi and KOReader rarely gets
  NetworkConnected. A failed send keeps that entry and the rest for the next try.
- Logging out clears the queue.

Install: copy to koreader/patches/ on the device and restart KOReader.
]]

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Persist = require("persist")
local PluginLoader = require("pluginloader")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

-- Same as the plugin's own
local API_CALL_DEBOUNCE_DELAY = time.s(25)
-- HTTP is synchronous here (no Turbo looper), so pause between queued sends to let
-- input through; a long queue would otherwise block long enough for an ANR.
local DRAIN_SEND_DELAY = 0.2

-- KOSyncQueue from upstream f3f88f7ca7, without the progress metadata that v2023.06.1's
-- sync API doesn't have, and with a load that never throws (it runs on document close).
local QUEUE_PATH = DataStorage:getSettingsDir() .. "/kosync_queue.lua"
local MAX_AGE = 28 * 24 * 3600 -- 4 weeks in seconds
local MAX_ENTRIES = 200 -- paranoia cap

local KOSyncQueue = {
    _draining = nil,
}

function KOSyncQueue:_storage()
    if not self._persist then
        self._persist = Persist:new{ path = QUEUE_PATH, codec = "dump" }
    end
    return self._persist
end

function KOSyncQueue:load()
    local storage = self:_storage()
    if not storage:exists() then return {} end
    local ok, data, err = pcall(storage.load, storage)
    if not ok or type(data) ~= "table" then
        logger.warn("KOSyncQueue: failed to load queue:", ok and err or data)
        return {}
    end
    return data
end

function KOSyncQueue:save(queue)
    local ok, err = self:_storage():save(queue)
    if not ok then
        logger.warn("KOSyncQueue: failed to save queue:", err)
    end
end

--- Queue a failed progress update for later retry.
-- Keeps one entry per document per day (for statistics granularity).
-- Expires entries older than 4 weeks.
function KOSyncQueue:push(item)
    if not item.document then return end
    local queue = self:load()
    local now = os.time()
    item.queued_at = now

    local today = math.floor(now / 86400)

    -- Filter: expire old entries, deduplicate same document+same day
    local filtered = {}
    for _, entry in ipairs(queue) do
        local dominated = entry.document == item.document
            and math.floor((entry.queued_at or 0) / 86400) == today
        if (now - (entry.queued_at or 0)) < MAX_AGE and not dominated then
            table.insert(filtered, entry)
        end
    end

    table.insert(filtered, item)

    -- Paranoia cap: drop oldest
    while #filtered > MAX_ENTRIES do
        table.remove(filtered, 1)
    end

    self:save(filtered)
    logger.dbg("KOSyncQueue: queued progress for", item.document, "total:", #filtered)
end

--- Drop the queued entries of a document whose current progress was just pushed,
-- so a later drain can't send an older position over it.
function KOSyncQueue:remove(document)
    local queue = self:load()
    local kept = {}
    for _, entry in ipairs(queue) do
        if entry.document ~= document then
            table.insert(kept, entry)
        end
    end
    if #kept < #queue then
        self:save(kept)
    end
end

-- Entries are flat tables of strings and numbers (util.tableEquals is newer than v2023.06.1)
local function sameEntry(a, b)
    for k, v in pairs(a) do
        if b[k] ~= v then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

--- Attempt to send all queued items in order, stopping on the first failure.
-- @param send_func function(item, callback): reports success through callback(bool)
-- @param done_func optional function(sent): called when the drain finishes
function KOSyncQueue:drain(send_func, done_func)
    -- Network events may arrive while an asynchronous request is still in flight.
    if self._draining then return end
    local queue = self:load()
    if #queue == 0 then
        if done_func then done_func(0) end
        return
    end
    self._draining = true

    logger.info("KOSyncQueue: draining", #queue, "queued items")
    local sent = 0
    local settled = false

    -- Both failure and queue exhaustion complete the drain exactly once.
    local function settle()
        if settled then return end
        settled = true
        self._draining = nil
        local ok, remaining = pcall(self.count, self)
        logger.info("KOSyncQueue: sent", sent, ", remaining", ok and remaining or "unknown")
        if done_func then done_func(sent) end
    end

    local function fail(err)
        if err then
            logger.warn("KOSyncQueue: drain failed:", err)
        end
        settle()
    end

    local function findItem(current, item)
        for i, entry in ipairs(current) do
            -- Compare the contents too: a same-day replacement can have the same
            -- document and queued_at when it was queued within the same second.
            if sameEntry(entry, item) then return i end
        end
    end

    local sendNext
    sendNext = function(i)
        if settled then return end
        local item = queue[i]
        if not item then
            settle()
            return
        end
        -- Do not send snapshot entries that have since been replaced or cleared.
        if not findItem(self:load(), item) then
            logger.dbg("KOSyncQueue: skipping replaced or cleared progress for", item.document)
            sendNext(i + 1)
            return
        end
        local completed = false
        local function callback(ok)
            if settled or completed then return end
            completed = true
            if not ok then
                fail()
                return
            end
            -- Reload after the request: pushes may have changed the queue in flight.
            local ok_book, err = pcall(function()
                local current = self:load()
                local index = findItem(current, item)
                if index then
                    table.remove(current, index)
                    self:save(current)
                end
                sent = sent + 1
            end)
            if not ok_book then
                fail(err)
                return
            end
            UIManager:scheduleIn(DRAIN_SEND_DELAY, sendNext, i + 1)
        end
        local ok, err = pcall(send_func, item, callback)
        if not ok then
            logger.warn("KOSyncQueue: failed to send queued progress:", err)
            callback(false)
        end
    end

    sendNext(1)
end

function KOSyncQueue:count()
    return #self:load()
end

function KOSyncQueue:clear()
    self:save({})
end

-- Same texts as the plugin's, so the existing translations apply
local function promptLogin()
    UIManager:show(InfoMessage:new{
        text = _("Please register or login before using the progress synchronization feature."),
        timeout = 3,
    })
end

local function showSyncError()
    UIManager:show(InfoMessage:new{
        text = _("Something went wrong when syncing progress, please check your network connection and try again later."),
        timeout = 3,
    })
end

local function patchKOSyncClient(KOSyncClient)
    -- As upstream: also pass the HTTP status, so a rejected login isn't queued, and call
    -- back on errors without reading .body from the error value. Also log a callback that
    -- throws, instead of losing it in the dead coroutine.
    function KOSyncClient:update_progress(
            username,
            password,
            document,
            progress,
            percentage,
            device,
            device_id,
            callback)
        self.client:reset_middlewares()
        self.client:enable('Format.JSON')
        self.client:enable("GinClient")
        self.client:enable("KOSyncAuth", {
            username = username,
            userkey = password,
        })
        local co = coroutine.create(function()
            local ok, res = pcall(function()
                return self.client:update_progress({
                    document = document,
                    progress = tostring(progress),
                    percentage = percentage,
                    device = device,
                    device_id = device_id,
                })
            end)
            if ok then
                callback(res.status == 200, res.body, res.status)
            else
                logger.dbg("KOSyncClient:update_progress failure:", res)
                callback(false)
            end
        end)
        self.client:enable("AsyncHTTP", {thread = co})
        local ok, err = coroutine.resume(co)
        if not ok then
            logger.warn("KOSyncClient:update_progress callback failed:", err)
        end
        if UIManager.looper then UIManager:setInputTimeout() end
    end
end

local function currentProgress(kosync)
    return {
        document = kosync:getDocumentDigest(),
        progress = kosync:getLastProgress(),
        percentage = kosync:getLastPercent(),
        device = Device.model,
        device_id = kosync.device_id,
    }
end

local function patchKOSync(KOSync)
    patchKOSyncClient(require("KOSyncClient"))

    -- v2023.06.1's, plus the upstream queueing of failed pushes, and sending the queue
    -- after a successful push.
    function KOSync:updateProgress(ensure_networking, interactive, refresh_on_success)
        if not self.settings.username or not self.settings.userkey then
            if interactive then
                promptLogin()
            end
            return
        end

        local now = UIManager:getElapsedTimeSinceBoot()
        if not interactive and now - self.push_timestamp <= API_CALL_DEBOUNCE_DELAY then
            logger.dbg("KOSync: We've already pushed progress less than 25s ago!")
            return
        end

        if ensure_networking and NetworkMgr:willRerunWhenOnline(function() self:updateProgress(ensure_networking, interactive, refresh_on_success) end) then
            return
        end

        local KOSyncClient = require("KOSyncClient")
        local client = KOSyncClient:new{
            custom_url = self.settings.custom_server,
            service_spec = self.path .. "/api.json"
        }
        local item = currentProgress(self)
        local ok, err = pcall(client.update_progress,
            client,
            self.settings.username,
            self.settings.userkey,
            item.document,
            item.progress,
            item.percentage,
            item.device,
            item.device_id,
            function(ok, body, status)
                logger.dbg("KOSync: [Push] progress to", item.percentage * 100, "% =>", item.progress, "for", self.view.document.file)
                logger.dbg("KOSync: ok:", ok, "body:", body)
                if ok then
                    if interactive then
                        UIManager:show(InfoMessage:new{
                            text = _("Progress has been pushed."),
                            timeout = 3,
                        })
                    end
                    -- The server is reachable: send what was queued while it wasn't
                    KOSyncQueue:remove(item.document)
                    UIManager:scheduleIn(DRAIN_SEND_DELAY, function() self:drainQueue() end)
                else
                    -- Queue for retry unless it's an auth failure
                    if status ~= 401 then
                        KOSyncQueue:push(item)
                    end
                    if interactive then showSyncError() end
                end
            end)
        if not ok then
            if interactive then showSyncError() end
            if err then logger.dbg("err:", err) end
            -- Network unreachable: queue for retry
            KOSyncQueue:push(item)
        else
            -- This is solely for onSuspend's sake, to clear the ghosting left by the the "Connected" InfoMessage
            if refresh_on_success then
                -- Our top-level widget should be the "Connected to network" InfoMessage from NetworkMgr's reconnectOrShowNetworkMenu
                local widget = UIManager:getTopmostVisibleWidget()
                if widget and widget.modal and widget.tag == "NetworkMgr" and not widget.dismiss_callback then
                    -- We want a full-screen flash on dismiss
                    widget.dismiss_callback = function()
                        -- Enqueued, because we run before the InfoMessage's close
                        UIManager:setDirty(nil, "full")
                    end
                end
            end
        end

        self.push_timestamp = now
    end

    function KOSync:_onCloseDocument()
        logger.dbg("KOSync: onCloseDocument")
        -- Nothing to push without an account (v2023.06.1 still waited for Wi-Fi here)
        if not self.settings.username or not self.settings.userkey then
            return
        end
        -- If we're already online, push normally.
        -- Otherwise, queue progress for later instead of blocking with goOnlineToRun.
        -- (isConnected first, because isOnline is a DNS lookup.)
        if NetworkMgr:isConnected() and NetworkMgr:isOnline() then
            self:updateProgress(false, false)
        else
            KOSyncQueue:push(currentProgress(self))
        end
    end

    function KOSync:_onNetworkConnected()
        logger.dbg("KOSync: onNetworkConnected")
        UIManager:scheduleIn(0.5, function()
            -- Drain any queued progress updates first
            self:drainQueue(function()
                -- Pull only after queued uploads have completed.
                -- Network is supposed to be on already, don't wrap this in willRerunWhenOnline
                self:getProgress(false, false)
            end)
        end)
    end

    function KOSync:drainQueue(done_func)
        if not self.settings.username or not self.settings.userkey or KOSyncQueue:count() == 0 then
            if done_func then done_func() end
            return
        end

        local KOSyncClient = require("KOSyncClient")
        local client = KOSyncClient:new{
            custom_url = self.settings.custom_server,
            service_spec = self.path .. "/api.json"
        }

        KOSyncQueue:drain(function(item, callback)
            client:update_progress(
                self.settings.username,
                self.settings.userkey,
                item.document,
                item.progress,
                item.percentage,
                item.device,
                item.device_id,
                callback)
        end, done_func)
    end

    local orig_logout = KOSync.logout
    function KOSync:logout(menu)
        -- Clear any queued progress for the old account
        KOSyncQueue:clear()
        return orig_logout(self, menu)
    end

    logger.info("kosync-offline-queue: patched the Progress sync plugin")
end

-- The plugin is loaded when the reader starts, after this patch runs, so patch its
-- class just before the first instance is created.
local orig_createPluginInstance = PluginLoader.createPluginInstance
function PluginLoader:createPluginInstance(plugin, attr)
    if plugin.name == "kosync" and not plugin._offline_queue_patched then
        plugin._offline_queue_patched = true
        local ok, err = pcall(patchKOSync, plugin)
        if not ok then
            logger.warn("kosync-offline-queue: patching failed:", err)
        end
    end
    return orig_createPluginInstance(self, plugin, attr)
end
