-- Copyright (C) 2026 zacharykim88
-- SPDX-License-Identifier: AGPL-3.0-only
-- Local-only HTTP endpoints. No upload, delete, directory navigation or shell access.
local Gallery = require("gallery")
local json = require("rapidjson")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local HTTP = {}

local STATUS = {
    [200] = "OK", [400] = "Bad Request", [404] = "Not Found",
    [405] = "Method Not Allowed", [413] = "Payload Too Large",
    [500] = "Internal Server Error",
}

local function sendAll(client, data)
    local index = 1
    while index <= #data do
        local last, _, partial = client:send(data, index)
        last = last or partial
        if type(last) ~= "number" or last < index then return false end
        index = last + 1
    end
    return true
end

local function header(status, mime, len, disposition)
    local h = {
        "HTTP/1.0 " .. status .. " " .. (STATUS[status] or "Error"),
        "Content-Type: " .. mime,
        "Content-Length: " .. len,
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
        "Connection: close",
    }
    if disposition then h[#h + 1] = "Content-Disposition: " .. disposition end
    return table.concat(h, "\r\n") .. "\r\n\r\n"
end

local function respond(client, status, mime, body, disposition)
    body = body or ""
    sendAll(client, header(status, mime, #body, disposition))
    sendAll(client, body)
    client:close()
end

local function respondFile(client, path, mime, disposition)
    local attrs = lfs.attributes(path)
    if not attrs or attrs.mode ~= "file" then
        return respond(client, 404, "text/plain; charset=utf-8", "File unavailable")
    end
    local file = io.open(path, "rb")
    if not file then
        return respond(client, 404, "text/plain; charset=utf-8", "File unavailable")
    end
    -- KOReader's SimpleTCPServer sets a 0.5-second total send timeout.
    -- Give Safari bounded time to accept the download, but never block forever.
    local ok, err = pcall(function()
        client:settimeout(5, "t")
        client:settimeout(3, "b")
        if not sendAll(client, header(200, mime, attrs.size, disposition)) then return end
        while true do
            local chunk = file:read(16384)
            if not chunk or #chunk == 0 then break end
            if not sendAll(client, chunk) then break end
        end
    end)
    -- A socket failure must not leak the open PNG/ZIP file handle.
    file:close()
    pcall(function() client:close() end)
    if not ok then error(err, 0) end
end

local function decode(raw)
    if type(raw) ~= "string" or raw:find("%%[^%x]") or raw:find("%%$")
        or raw:find("%%[%x]$") then return nil end
    local str = raw:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
    if str:find("\0", 1, true) then return nil end
    return str
end

local function queryValues(query, key)
    local values = {}
    for part in (query or ""):gmatch("[^&]+") do
        local k, v = part:match("^([^=]+)=(.*)$")
        if k == key then
            local value = decode(v)
            if not value then return nil end
            values[#values + 1] = value
        end
    end
    return values
end

local function filenameDisposition(filename)
    -- A constant ASCII fallback; RFC 5987 preserves the actual UTF-8 name.
    local escaped = filename:gsub("([^%w%-%._~])", function(c)
        return string.format("%%%02X", c:byte())
    end)
    return 'attachment; filename="screenshot.png"; filename*=UTF-8\'\'' .. escaped
end

local function listJSON()
    local files = Gallery.list()
    local out = {}
    for _, f in ipairs(files) do
        out[#out + 1] = { name = f.name, size = f.size, modified = f.modified }
    end
    return json.encode({ files = out, max_selection = 10 })
end

function HTTP.removeStaleZIP()
    -- Only remove the plugin's own temporary archive, never screenshots.
    return os.remove(DataStorage:getFullDataDir() .. "/inkshare-batch.tmp.zip")
end

local function createZIP(items)
    local ok_mod, Archiver = pcall(require, "ffi/archiver")
    if not ok_mod or not Archiver then return nil, "Archiver unavailable" end
    local path = DataStorage:getFullDataDir() .. "/inkshare-batch.tmp.zip"
    -- At most one request is processed at a time by SimpleTCPServer.
    os.remove(path)
    local writer = Archiver.Writer:new{}
    local opened, open_result = pcall(writer.open, writer, path, "zip")
    if not opened or not open_result then
        os.remove(path)
        return nil, tostring(opened and writer.err or open_result)
    end
    local set_ok, store_result = pcall(writer.setZipCompression, writer, "store")
    if not set_ok or not store_result then
        pcall(writer.close, writer)
        os.remove(path)
        return nil, "Could not select ZIP storage method"
    end
    local success, err = pcall(function()
        for _, f in ipairs(items) do
            -- The KOReader libarchive addPath helper may return false at EOF,
            -- even after adding the file. Use the explicit, checked memory API
            -- with one screenshot at a time (PNG files are typically small).
            local input, open_err = io.open(f.path, "rb")
            if not input then
                error("Cannot open screenshot: " .. f.name .. ": " .. tostring(open_err))
            end
            local body = input:read("*a")
            input:close()
            if not body then
                error("Cannot read screenshot: " .. f.name)
            end
            if not writer:addFileFromMemory(f.name, body, f.modified) then
                error("Cannot add screenshot to ZIP: " .. f.name .. ": " .. tostring(writer.err))
            end
        end
    end)
    local closed, close_err = pcall(function() writer:close() end)
    if not success or not closed then
        os.remove(path)
        return nil, tostring(not success and err or close_err)
    end
    return path
end

function HTTP.handle(request, client)
    local method, target = request:match("^(%u+)%s+([^%s]+)%s+HTTP/%d%.%d")
    if method ~= "GET" then
        return respond(client, 405, "text/plain; charset=utf-8", "GET only")
    end
    if not target then
        return respond(client, 400, "text/plain; charset=utf-8", "Invalid HTTP request")
    end
    local path, query = target:match("^([^?]+)%??(.*)$")
    if path == "/" then
        return respond(client, 200, "text/html; charset=utf-8", require("page"))
    elseif path == "/api/files" then
        return respond(client, 200, "application/json; charset=utf-8", listJSON())
    elseif path == "/image" or path == "/download" then
        local vals = queryValues(query, "f")
        if not vals or #vals ~= 1 then
            return respond(client, 400, "text/plain; charset=utf-8", "Specify exactly one file")
        end
        local file = Gallery.resolve(vals[1])
        if not file then
            return respond(client, 404, "text/plain; charset=utf-8", "Screenshot not found")
        end
        local disposition = (path == "/download") and filenameDisposition(file.name) or nil
        return respondFile(client, file.path, "image/png", disposition)
    elseif path == "/batch" then
        local vals = queryValues(query, "f")
        if not vals or #vals < 2 or #vals > 10 then
            return respond(client, 400, "text/plain; charset=utf-8", "Select 2 to 10 screenshots")
        end
        local snapshot = Gallery.list()
        local seen, selected = {}, {}
        for _, name in ipairs(vals) do
            if seen[name] then
                return respond(client, 400, "text/plain; charset=utf-8", "Duplicate screenshot")
            end
            seen[name] = true
            local file = Gallery.resolve(name, snapshot)
            if not file then
                return respond(client, 404, "text/plain; charset=utf-8", "Screenshot not found")
            end
            selected[#selected + 1] = file
        end
        local archive, err = createZIP(selected)
        if not archive then
            return respond(client, 500, "text/plain; charset=utf-8", "ZIP creation failed: " .. tostring(err))
        end
        local ok_send, result = pcall(respondFile, client, archive, "application/zip", 'attachment; filename="koreader-screenshots.zip"')
        -- Clean up even if an unexpected socket/file error escapes respondFile.
        os.remove(archive)
        if not ok_send then error(result, 0) end
        return result
    end
    return respond(client, 404, "text/plain; charset=utf-8", "Not found")
end

return HTTP
