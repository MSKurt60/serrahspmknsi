local config = getPmConfig and getPmConfig() or {
    maxMessageLength = 256,
}

local ui = {
    window = nil,
    grid = nil,
    accountEdit = nil,
    memo = nil,
    sendBtn = nil,
    closeBtn = nil,
}

local function createUi()
    if ui.window and isElement(ui.window) then return end
    local sx, sy = guiGetScreenSize()
    local w, h = 520, 420
    local x, y = (sx - w) / 2, (sy - h) / 2
    ui.window = guiCreateWindow(x, y, w, h, "Özel Mesaj Paneli", false)
    guiWindowSetSizable(ui.window, false)

    ui.grid = guiCreateGridList(10, 25, 240, h - 35, false, ui.window)
    guiGridListAddColumn(ui.grid, "Online Oyuncular", 0.9)

    guiCreateLabel(260, 30, 240, 18, "Offline gönderim için hesap adı:", false, ui.window)
    ui.accountEdit = guiCreateEdit(260, 50, 240, 24, "", false, ui.window)

    ui.memo = guiCreateMemo(260, 90, 240, 240, "", false, ui.window)

    ui.sendBtn = guiCreateButton(260, 340, 115, 30, "Gönder", false, ui.window)
    ui.closeBtn = guiCreateButton(385, 340, 115, 30, "Kapat", false, ui.window)

    addEventHandler("onClientGUIClick", ui.sendBtn, function()
        local content = guiGetText(ui.memo)
        if not content or content == "" then
            outputChatBox("[PM] Mesaj boş olamaz.", 255, 64, 64)
            return
        end
        if utf8.len(content) > config.maxMessageLength then
            outputChatBox("[PM] Mesaj çok uzun.", 255, 64, 64)
            return
        end

        local accountTarget = guiGetText(ui.accountEdit)
        if accountTarget and accountTarget ~= "" then
            triggerServerEvent("pm:sendMessage", localPlayer, { mode = "account", receiverAccount = accountTarget, content = content })
            return
        end

        local row = guiGridListGetSelectedItem(ui.grid)
        if row and row ~= -1 then
            local target = guiGridListGetItemData(ui.grid, row, 1)
            if isElement(target) then
                triggerServerEvent("pm:sendMessage", localPlayer, { mode = "online", receiverPlayer = target, content = content })
                return
            end
        end

        outputChatBox("[PM] Bir alıcı seçin veya hesap adı girin.", 255, 64, 64)
    end, false)

    addEventHandler("onClientGUIClick", ui.closeBtn, function()
        if ui.window then
            guiSetVisible(ui.window, false)
            showCursor(false)
        end
    end, false)

    guiSetVisible(ui.window, false)
end

local function refreshPlayerList()
    if not ui.window or not isElement(ui.window) then return end
    guiGridListClear(ui.grid)
    for _, p in ipairs(getElementsByType("player")) do
        local row = guiGridListAddRow(ui.grid)
        guiGridListSetItemText(ui.grid, row, 1, getPlayerName(p), false, false)
        guiGridListSetItemData(ui.grid, row, 1, p)
    end
end

local function togglePanel()
    createUi()
    local visible = not guiGetVisible(ui.window)
    guiSetVisible(ui.window, visible)
    showCursor(visible)
    if visible then
        refreshPlayerList()
    end
end

addCommandHandler("pmpanel", function()
    togglePanel()
end)

bindKey("F7", "down", function()
    togglePanel()
end)

-- Receive single incoming message
addEvent("pm:receiveMessage", true)
addEventHandler("pm:receiveMessage", resourceRoot, function(data)
    if type(data) ~= "table" then return end
    local ts = data.ts or 0
    local time = getRealTime(ts)
    local stamp = string.format("%02d:%02d", time.hour, time.minute)
    outputChatBox(string.format("#7AD37A[PM][%s] #FFFFFF%s: %s", stamp, tostring(data.sender), tostring(data.content)), 255, 255, 255, true)
    playSoundFrontEnd(12)
end)

-- Receive a batch of undelivered messages after login
addEvent("pm:deliverUndelivered", true)
addEventHandler("pm:deliverUndelivered", resourceRoot, function(rows)
    if type(rows) ~= "table" then return end
    if #rows > 0 then
        outputChatBox(string.format("#7AD37A[PM] #FFFFFF%d bekleyen mesajınız var.", #rows), 255, 255, 255, true)
        for _, row in ipairs(rows) do
            local ts = tonumber(row.created_at) or 0
            local time = getRealTime(ts)
            local stamp = string.format("%02d:%02d", time.hour, time.minute)
            outputChatBox(string.format("#7AD37A[PM][%s] #FFFFFF%s: %s", stamp, tostring(row.sender), tostring(row.content)), 255, 255, 255, true)
        end
        playSoundFrontEnd(12)
    end
end)

-- Periodically refresh the player list when panel is open
setTimer(function()
    if ui.window and isElement(ui.window) and guiGetVisible(ui.window) then
        refreshPlayerList()
    end
end, 5000, 0)
