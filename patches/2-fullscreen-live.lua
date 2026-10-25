--[[
Makes KOReader's Fullscreen toggle (the menu item and the "Toggle Fullscreen"
gesture action) take effect right away instead of asking for a restart.

For the Icarus Illumina E653 (Android 4.2, API 17) with the patched launcher from
this repo. On API 16-18, Device:toggleFullscreen() only switches the
screen viewport (758x1024 <-> 758x944), and the menu item then asks for a
restart because nothing tells the open views that the screen size changed.
This sends them the same events KOReader sends when Android resizes its window
(APP_CMD_CONFIG_CHANGED in frontend/device/android/device.lua).

Install: copy to koreader/patches/ on the device and restart KOReader.
]]

local Device = require("device")
if not Device:isAndroid() or Device:isAlwaysFullscreen() then return end

local Event = require("ui/event")
local MenuSorter = require("ui/menusorter")
local UIManager = require("ui/uimanager")
local android = require("android")
local ffi = require("ffi")
local logger = require("logger")

local C = ffi.C

-- Upstream only sets Device.fullscreen on a toggle, so after a start in
-- fullscreen (the default) the menu's checkbox read "off".
Device.fullscreen = android.isFullscreen()

local function relayout()
    local new_size = Device.screen:getSize()
    logger.info("fullscreen-live: relayout to", new_size)
    -- closes any open menu, re-renders the book and rebuilds touch zones
    UIManager:broadcastEvent(Event:new("SetDimensions", new_size))
    UIManager:broadcastEvent(Event:new("ScreenResize", new_size))
    UIManager:broadcastEvent(Event:new("RedrawCurrentPage"))
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:reinit(FileManager.instance.path, FileManager.instance.focused_file)
    end
    -- the whole page changed, so flash it like a rotation does
    UIManager:setDirty("all", "full")
end

-- Device:init() has already run its own toggle (for disable_android_fullscreen)
-- by the time late patches load, so this only sees the user's toggles.
local orig_toggleFullscreen = Device.toggleFullscreen
function Device:toggleFullscreen()
    orig_toggleFullscreen(self)
    -- let the menu that called us finish updating its checkmark first
    UIManager:nextTick(relayout)
end

local orig_mergeAndSort = MenuSorter.mergeAndSort
function MenuSorter:mergeAndSort(config_prefix, item_table, order)
    if (config_prefix == "filemanager" or config_prefix == "reader") and item_table.fullscreen then
        -- same as upstream's callback, minus UIManager:askForRestart()
        item_table.fullscreen.callback = function()
            Device:toggleFullscreen()
        end
    end
    return orig_mergeAndSort(self, config_prefix, item_table, order)
end

-- The launcher shows or hides the system bar on the UI thread, so the window can
-- resize after the relayout has already been drawn into the old-size buffer. The
-- stock handler ignores APP_CMD_WINDOW_RESIZED; copy the screen into the new one.
local orig_handleMiscEv = Device.input.handleMiscEv
Device.input.handleMiscEv = function(this, ev)
    if ev.code == C.APP_CMD_WINDOW_RESIZED then
        this.device.screen:_updateWindow()
    end
    return orig_handleMiscEv(this, ev)
end
