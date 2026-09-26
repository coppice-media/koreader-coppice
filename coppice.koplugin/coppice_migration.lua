--[[--
Safe retirement of the historical plugin install.

Migration deliberately deletes the old settings file instead of importing it:
old settings may contain an account secret that the password-based client used,
and pairing is the only supported way to obtain fresh Coppice credentials.
Unknown files in the old directory are never recursively removed.
]]

local Migration = {}

Migration.OLD_SETTINGS = {
    "stump.lua",
    "stump.koplugin.lua",
}

Migration.OLD_PLUGIN_FILES = {
    "main.lua",
    "main.luac",
    "_meta.lua",
    "_meta.luac",
    "stump_api.lua",
    "stump_api.luac",
    "stump_annotations.lua",
    "stump_annotations.luac",
    "stump_browser.lua",
    "stump_browser.luac",
    "stump_kosync.lua",
    "stump_kosync.luac",
    "stump_opds.lua",
    "stump_opds.luac",
    "stump_url.lua",
    "stump_url.luac",
}

local function join(root, name)
    if type(root) ~= "string" or root == "" then return nil end
    return root:gsub("/$", "") .. "/" .. name
end

--- Returns only the paths that this migration is allowed to remove.
---
--- Keeping this list pure makes the destructive boundary reviewable and lets
--- tests prove that no broad recursive deletion or credential import exists.
function Migration.removalPlan(plugin_root, settings_dir)
    local paths = {}
    for _unused, name in ipairs(Migration.OLD_SETTINGS) do
        local path = join(settings_dir, name)
        if path then paths[#paths + 1] = path end
    end
    local old_plugin = join(plugin_root, "stump.koplugin")
    if old_plugin then
        for _unused, name in ipairs(Migration.OLD_PLUGIN_FILES) do
            paths[#paths + 1] = old_plugin .. "/" .. name
        end
    end
    return paths
end

--- Removes obsolete files and then removes the old directory only when empty.
--- `remove` and `rmdir` are injectable for pure tests.
function Migration.run(plugin_root, settings_dir, remove, rmdir)
    remove = remove or os.remove
    rmdir = rmdir or function(path)
        local ok, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok or not lfs or not lfs.rmdir then return nil end
        return lfs.rmdir(path)
    end

    local plan = Migration.removalPlan(plugin_root, settings_dir)
    for _unused, path in ipairs(plan) do
        pcall(remove, path)
    end

    local old_plugin = join(plugin_root, "stump.koplugin")
    if old_plugin then pcall(rmdir, old_plugin) end
    return plan
end

return Migration
