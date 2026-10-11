-- Copyright (C) 2026 zacharykim88
-- SPDX-License-Identifier: AGPL-3.0-only
-- During an explicit sharing session, temporarily suspend KOReader's
-- *idle* Wi-Fi-off timer without changing the user's persisted preference.
-- The timer is restored when sharing stops, if still connected.
local NetworkMgr = require("ui/network/manager")
local Wifi = { paused = false, listener = nil }

local function needKeepAlive()
    return G_reader_settings:isTrue("auto_disable_wifi")
end

function Wifi:pause()
    if not needKeepAlive() then return true end
    local ok, listener = pcall(require, "ui/network/networklistener")
    if not ok or not listener or type(listener._unscheduleActivityCheck) ~= "function" then
        return false, "当前 KOReader 不支持暂停 Wi-Fi 闲置关闭计时器。"
    end
    local success, err = pcall(listener._unscheduleActivityCheck, listener)
    if not success then return false, "暂停 Wi-Fi 闲置计时器失败：" .. tostring(err) end
    self.listener = listener
    self.paused = true
    return true
end

function Wifi:resume()
    if not self.paused then return true end
    self.paused = false
    local listener = self.listener
    self.listener = nil
    if not needKeepAlive() then return true end
    local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
    if not ok or not connected then return true end
    if not listener or type(listener._scheduleActivityCheck) ~= "function" then
        return false, "无法恢复 Wi-Fi 闲置计时器。"
    end
    local success, err = pcall(listener._scheduleActivityCheck, listener)
    if not success then return false, "恢复 Wi-Fi 闲置计时器失败：" .. tostring(err) end
    return true
end

return Wifi
