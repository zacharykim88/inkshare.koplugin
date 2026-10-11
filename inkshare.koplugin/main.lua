-- Copyright (C) 2026 zacharykim88
-- SPDX-License-Identifier: AGPL-3.0-only
-- InkShare: KOReader screenshot sharing over the local network.
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local QRMessage = require("ui/widget/qrmessage")
local NetworkMgr = require("ui/network/manager")
local Runtime = require("runtime")
local Wifi = require("wifi")
local logger = require("logger")

local InkShare = WidgetContainer:extend{ name = "inkshare", is_doc_only = false }

local function info(message)
    UIManager:show(InfoMessage:new{ text = message })
end

function InkShare:init()
    self.ui.menu:registerToMainMenu(self)
end

function InkShare:showQR()
    local url = Runtime:url()
    if not url then
        info("网络地址暂时不可用；请确认 Wi-Fi 已连接。")
        return
    end
    UIManager:show(QRMessage:new{
        text = url,
        -- Keep enough quiet space around the QR for close-range scanning.
        width = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.60),
        height = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.60),
    })
    -- Closing this QR widget intentionally does NOT stop the server.
end

-- Project information and an optional QR link to the author's other KOReader work.
function InkShare:showAbout()
    local ButtonDialog = require("ui/widget/buttondialog")
    local inkfolio_url = "https://github.com/zacharykim88/Inkfolio"
    local dialog
    dialog = ButtonDialog:new{
        title = table.concat({
            "墨享 · InkShare",
            "KOReader 局域网截图分享插件",
            "",
            "版本：v1.0.0",
            "开发者：zacharykim88",
            "许可证：AGPL-3.0-only",
            "项目地址：github.com/zacharykim88/inkshare.koplugin",
            "已验证：Kobo Sage + iPhone Safari",
            "分享方式：局域网 HTTP（无密码）",
            "",
            "同作者作品推荐",
            "墨笺 · Inkfolio",
            "将书籍信息、阅读进度和天气制成电影票根风格小票，支持预览与兼容设备的休眠壁纸。",
            "GitHub：github.com/zacharykim88/Inkfolio",
        }, "\n"),
        buttons = {
            {
                {
                    text = "关闭",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = "扫码查看墨笺",
                    callback = function()
                        UIManager:close(dialog)
                        local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.60)
                        UIManager:show(QRMessage:new{
                            text = inkfolio_url,
                            width = size,
                            height = size,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function InkShare:requestStart()
    if Runtime:isRunning() then
        self:showQR()
        return
    end
    local requestID = Runtime:beginRequest()
    local function finish()
        if Runtime.requestID ~= requestID or not Runtime.requested then return false end
        Runtime:cancelPending()
        return true
    end
    -- NetworkMgr may never invoke its callback after a failed Wi-Fi connection.
    Runtime.requestTimer = function()
        Runtime.requestTimer = nil
        if finish() then
            Runtime.requested = false
            info("Wi-Fi 连接超时，请检查网络后重新开启截图分享。")
        end
    end
    UIManager:scheduleIn(60, Runtime.requestTimer)
    -- Only a LAN connection is required; internet access is unnecessary.
    local ok, err = pcall(function()
        NetworkMgr:runWhenConnected(function()
            if not finish() then return end
            local started, start_err = Runtime:start()
            if not started then
                Runtime.requested = false
                info(start_err)
                return
            end
            self:showQR()
        end)
    end)
    if not ok and finish() then
        Runtime.requested = false
        info("Wi-Fi 连接失败：" .. tostring(err))
    end
end

function InkShare:addToMainMenu(menu_items)
    menu_items.inkshare = {
        text = "墨享（InkShare）",
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    if Runtime:isRunning() then return "关闭截图分享" end
                    if Runtime.requested then return "取消开启截图分享" end
                    return "开启截图分享"
                end,
                keep_menu_open = true,
                callback = function(menu)
                    local was_running = Runtime:isRunning()
                    if was_running or Runtime.requested then
                        Runtime:stop()
                        if menu and menu.updateItems then menu:updateItems() end
                        info(was_running and "截图分享已关闭，手机已无法访问。" or "已取消开启截图分享。")
                    else
                        -- The QR dialog is modal. Close the menu before showing it,
                        -- otherwise the old menu remains underneath and can consume
                        -- an apparent first tap on the stop action.
                        if menu and menu.closeMenu then menu:closeMenu() end
                        self:requestStart()
                    end
                end,
            },
            {
                text_func = function()
                    if Runtime:isRunning() then return "当前状态：分享中" end
                    if Runtime.requested then return "当前状态：正在连接 Wi-Fi" end
                    return "当前状态：已关闭"
                end,
                enabled_func = function() return false end,
            },
            {
                text = "显示分享二维码",
                enabled_func = function() return Runtime:isRunning() end,
                keep_menu_open = true,
                callback = function(menu)
                    if menu and menu.closeMenu then menu:closeMenu() end
                    self:showQR()
                end,
            },
            {
                text = "关于墨享",
                keep_menu_open = true,
                callback = function(menu)
                    if menu and menu.closeMenu then menu:closeMenu() end
                    self:showAbout()
                end,
            },
        },
    }
end

function InkShare:onEnterStandby() Runtime:stop() end
function InkShare:onSuspend() Runtime:stop() end
function InkShare:onExit() Runtime:stop() end
-- onCloseWidget is intentionally not a teardown event: KOReader may recreate
-- the plugin when switching from file-manager to reader or changing books.
-- onResume/onLeaveStandby intentionally do not restart sharing.
function InkShare:onNetworkConnected()
    if Runtime:isRunning() then
        Runtime.ip = Runtime.resolveIP() or Runtime.ip
        -- Defer until other listeners have processed NetworkConnected.
        UIManager:nextTick(function()
            if Runtime:isRunning() then
                local ok, err = Wifi:pause()
                if not ok then logger.warn("inkshare: " .. tostring(err)) end
            end
        end)
    end
end

return InkShare
