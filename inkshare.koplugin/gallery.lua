-- Copyright (C) 2026 zacharykim88
-- SPDX-License-Identifier: AGPL-3.0-only
-- Screenshot discovery. No paths received from HTTP clients are ever opened.
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local util = require("util")
local Gallery = {}

function Gallery.directory()
    local custom = G_reader_settings:readSetting("screenshot_dir")
    if type(custom) == "string" and custom ~= "" and util.makePath(custom) then
        return (custom:gsub("/$", ""))
    end
    return DataStorage:getFullDataDir() .. "/screenshots"
end

function Gallery.list()
    local dir = Gallery.directory()
    local ok, iter, state, ctrl = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then
        return {}
    end
    local items = {}
    for name in iter, state, ctrl do
        if type(name) == "string" and name:sub(1, 1) ~= "."
            and name:lower():match("%.png$") then
            local path = dir .. "/" .. name
            -- Do not follow symlinks: a linked *.png could point outside this folder.
            local attr = lfs.symlinkattributes and lfs.symlinkattributes(path)
            if attr and attr.mode == "file" then
                items[#items + 1] = {
                    name = name,
                    path = path,
                    size = attr.size or 0,
                    modified = attr.modification or 0,
                }
            end
        end
    end
    table.sort(items, function(a, b)
        if a.modified ~= b.modified then return a.modified > b.modified end
        return a.name < b.name
    end)
    return items
end

function Gallery.resolve(name, items)
    if type(name) ~= "string" or name == "" or name:find("/", 1, true)
        or name:find("\\", 1, true) or name:find("\0", 1, true) then
        return nil
    end
    for _, item in ipairs(items or Gallery.list()) do
        if item.name == name then return item end
    end
    return nil
end

return Gallery
