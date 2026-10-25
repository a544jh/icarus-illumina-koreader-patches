--[[
Adds an "Android home" item right above "Exit" in the last tab of KOReader's menu
(file browser and reader), which opens the Android home screen.

For the Icarus Illumina E653: it has no hardware Home key, and the system bar
(with its Home button) is hidden while KOReader is in fullscreen.

Install: copy to koreader/patches/ on the device and restart KOReader.
]]

local Device = require("device")
if not Device:isAndroid() then return end

local ffi = require("ffi")
local android = require("android")
local logger = require("logger")
local MenuSorter = require("ui/menusorter")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local C = ffi.C

local FLAG_ACTIVITY_NEW_TASK = 0x10000000

-- startActivity(new Intent(ACTION_MAIN).addCategory(CATEGORY_HOME)), done with
-- raw JNI because android.lua keeps its JNI helper local. Same attach/detach
-- pattern as JNI:context() there.
local function goHome()
    local vm = android.app.activity.vm
    local envp = ffi.new("JNIEnv*[1]")
    vm[0].GetEnv(vm, ffi.cast("void**", envp), C.JNI_VERSION_1_6)
    if vm[0].AttachCurrentThread(vm, envp, nil) == C.JNI_ERR then
        logger.warn("android-home: cannot attach to the JVM")
        return
    end
    local env = envp[0]

    local intent_class = env[0].FindClass(env, "android/content/Intent")
    local init = env[0].GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V")
    local add_category = env[0].GetMethodID(env, intent_class, "addCategory",
        "(Ljava/lang/String;)Landroid/content/Intent;")
    local set_flags = env[0].GetMethodID(env, intent_class, "setFlags", "(I)Landroid/content/Intent;")

    local action = env[0].NewStringUTF(env, "android.intent.action.MAIN")
    local category = env[0].NewStringUTF(env, "android.intent.category.HOME")
    local intent = env[0].NewObject(env, intent_class, init, action)
    env[0].DeleteLocalRef(env, env[0].CallObjectMethod(env, intent, add_category, category))
    env[0].DeleteLocalRef(env, env[0].CallObjectMethod(env, intent, set_flags,
        ffi.new("int32_t", FLAG_ACTIVITY_NEW_TASK)))

    local activity = android.app.activity.clazz
    local activity_class = env[0].GetObjectClass(env, activity)
    local start_activity = env[0].GetMethodID(env, activity_class, "startActivity",
        "(Landroid/content/Intent;)V")
    env[0].CallVoidMethod(env, activity, start_activity, intent)
    if env[0].ExceptionCheck(env) == C.JNI_TRUE then
        env[0].ExceptionDescribe(env)
        env[0].ExceptionClear(env)
        logger.warn("android-home: startActivity failed")
    end

    for _, ref in ipairs({ activity_class, intent, category, action, intent_class }) do
        env[0].DeleteLocalRef(env, ref)
    end
    vm[0].DetachCurrentThread(vm)
end

local function insertBeforeExit(main)
    for _, id in ipairs(main) do
        if id == "android_home" then return end
    end
    for i, id in ipairs(main) do
        if id == "exit_menu" then
            table.insert(main, i, "android_home")
            return
        end
    end
    table.insert(main, "android_home")
end

local orig_mergeAndSort = MenuSorter.mergeAndSort
function MenuSorter:mergeAndSort(config_prefix, item_table, order)
    if (config_prefix == "filemanager" or config_prefix == "reader") and order.main then
        item_table.android_home = {
            -- not just "Home": KOReader's home folder is also called that
            text = _("Android home"),
            callback = function()
                -- TouchMenu closes the menu right after this returns
                UIManager:nextTick(goHome)
            end,
        }
        insertBeforeExit(order.main)
    end
    return orig_mergeAndSort(self, config_prefix, item_table, order)
end
