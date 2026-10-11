-- Copyright (C) 2026 zacharykim88
-- SPDX-License-Identifier: AGPL-3.0-only
-- One runtime for all KOReader reader/file-manager plugin instances.
local Runtime = { port = 51423, server = nil, registered = nil, requested = false, ip = nil }
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Wifi = require("wifi")

function Runtime.resolveIP()
    local socket = require("socket")
    local udp = socket.udp()
    if not udp then return nil end
    -- No packet is sent: this only asks the OS which interface it would route via.
    local ok = udp:setpeername("203.0.113.1", 53)
    local ip
    if ok then ip = udp:getsockname() end
    udp:close()
    if type(ip) ~= "string" or ip == "0.0.0.0" or ip:match("^127%.") then
        return nil
    end
    return ip
end

function Runtime:beginRequest()
    self:cancelPending()
    self.requested = true
    return self.requestID
end

function Runtime:cancelPending()
    self.requestID = (self.requestID or 0) + 1
    if self.requestTimer then
        UIManager:unschedule(self.requestTimer)
        self.requestTimer = nil
    end
end

function Runtime:isRunning()
    return self.server ~= nil
end

function Runtime:start()
    if self:isRunning() then return true end
    local ip = self.resolveIP()
    if not ip then return false, "无法获取阅读器的局域网 IPv4 地址。" end
    local ServerClass = require("ui/message/simpletcpserver")
    local Handler = require("http")
    local server = ServerClass:new{
        host = "*", port = self.port,
        receiveCallback = function(request, client)
            local ok, err = pcall(Handler.handle, request, client)
            if not ok then
                logger.err("inkshare: HTTP handler failed", err)
                pcall(function() client:close() end)
            end
        end,
    }
    local ok, err = server:start()
    if not ok then return false, "无法监听端口 " .. self.port .. ": " .. tostring(err) end
    local ok_register, registered = pcall(function() return UIManager:insertZMQ(server) end)
    if not ok_register then
        server:stop()
        return false, "无法注册网络服务事件。"
    end
    self.server = server
    self.registered = registered
    self.ip = ip
    self.requested = true
    -- The event loop may already have scheduled KOReader's Wi-Fi idle timer.
    local held, wifi_err = Wifi:pause()
    if not held then
        self:stop()
        return false, wifi_err
    end
    -- Remove temporary ZIPs left by a previous crash or forced shutdown.
    Handler.removeStaleZIP()
    logger.info("inkshare: server started on", self.ip, self.port)
    return true
end

function Runtime:stop()
    self:cancelPending()
    self.requested = false
    if self.registered then
        UIManager:removeZMQ(self.registered)
        self.registered = nil
    end
    if self.server then
        pcall(function() self.server:stop() end)
        self.server = nil
    end
    self.ip = nil
    local ok, err = Wifi:resume()
    if not ok then logger.warn("inkshare: " .. tostring(err)) end
    logger.info("inkshare: stopped")
end

function Runtime:url()
    -- A changed DHCP address should be reflected when the QR is re-opened.
    self.ip = self.resolveIP() or self.ip
    if not self.ip then return nil end
    return string.format("http://%s:%d/", self.ip, self.port)
end

return Runtime
