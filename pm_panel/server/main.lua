local config = getPmConfig and getPmConfig() or {
    databaseFile = "pm_panel.db",
    rateLimitMs = 1500,
    maxMessageLength = 256,
    historyLimit = 50,
}

local db = nil
local lastSendTickByAccount = {}

local function getAccountNameForPlayer(player)
    if not isElement(player) or getElementType(player) ~= "player" then
        return nil
    end
    local account = getPlayerAccount(player)
    if not account or isGuestAccount(account) then
        return nil
    end
    return getAccountName(account)
end

local function ensureDatabaseSchema()
    db = dbConnect("sqlite", config.databaseFile)
    if not db then
        outputServerLog("[pm_panel] Failed to connect to SQLite DB: " .. tostring(config.databaseFile))
        return false
    end

    dbExec(db, [[
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sender TEXT NOT NULL,
            receiver TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            delivered INTEGER NOT NULL DEFAULT 0,
            delivered_at INTEGER
        );
    ]])

    dbExec(db, [[CREATE INDEX IF NOT EXISTS idx_messages_receiver_delivered ON messages (receiver, delivered);]])
    dbExec(db, [[CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages (created_at);]])

    return true
end

local function saveMessage(senderAccount, receiverAccount, content, markDelivered)
    if not db then return false end
    local now = getRealTime().timestamp
    local delivered = markDelivered and 1 or 0
    local deliveredAt = markDelivered and now or nil
    return dbExec(db,
        "INSERT INTO messages (sender, receiver, content, created_at, delivered, delivered_at) VALUES (?, ?, ?, ?, ?, ?)",
        senderAccount, receiverAccount, content, now, delivered, deliveredAt
    )
end

local function fetchUndelivered(receiverAccount)
    if not db then return {} end
    local qh = dbQuery(db, "SELECT id, sender, content, created_at FROM messages WHERE receiver = ? AND delivered = 0 ORDER BY created_at ASC", receiverAccount)
    local results = dbPoll(qh, -1) or {}
    return results
end

local function markDelivered(messageIds)
    if not db or not messageIds or #messageIds == 0 then return false end
    local now = getRealTime().timestamp
    -- Build a dynamic placeholders string like: ?, ?, ?
    local placeholders = table.concat({unpack(messageIds)} , ",") -- not used directly, build safely
    -- Build params list and statement safely
    local marks = {}
    local params = { now }
    for _ , _ in ipairs(messageIds) do
        table.insert(marks, "?")
    end
    local whereIn = table.concat(marks, ",")
    for _, id in ipairs(messageIds) do
        table.insert(params, id)
    end
    local sql = string.format("UPDATE messages SET delivered = 1, delivered_at = ? WHERE id IN (%s)", whereIn)
    return dbExec(db, sql, unpack(params))
end

local function isRateLimited(senderAccount)
    if not senderAccount then return true, 0 end
    local nowTick = getTickCount()
    local lastTick = lastSendTickByAccount[senderAccount] or 0
    local elapsed = nowTick - lastTick
    if elapsed < config.rateLimitMs then
        return true, config.rateLimitMs - elapsed
    end
    lastSendTickByAccount[senderAccount] = nowTick
    return false, 0
end

local function findPlayerByPartialName(partial)
    if not partial or partial == "" then return nil end
    local lower = string.lower(partial)
    local bestMatch = nil
    for _, p in ipairs(getElementsByType("player")) do
        local name = getPlayerName(p)
        if name and string.find(string.lower(name), lower, 1, true) then
            if not bestMatch then
                bestMatch = p
            else
                -- Ambiguous; prefer exact (case-insensitive) match
                if string.lower(name) == lower then
                    return p
                end
            end
        end
    end
    return bestMatch
end

local function deliverToOnline(receiverPlayer, senderAccount, content)
    if not isElement(receiverPlayer) then return false end
    triggerClientEvent(receiverPlayer, "pm:receiveMessage", resourceRoot, {
        sender = senderAccount,
        content = content,
        ts = getRealTime().timestamp
    })
    return true
end

-- Event: client requests to send a PM either to an online player or to an account name
addEvent("pm:sendMessage", true)
addEventHandler("pm:sendMessage", root, function(payload)
    if type(payload) ~= "table" then return end
    local senderPlayer = client or source
    if not isElement(senderPlayer) then return end

    local senderAccount = getAccountNameForPlayer(senderPlayer)
    if not senderAccount then
        outputChatBox("[PM] Mesaj göndermek için giriş yapmalısınız.", senderPlayer, 255, 64, 64)
        return
    end

    local content = tostring(payload.content or "")
    if content == "" or utf8.len(content) == 0 then
        outputChatBox("[PM] Mesaj boş olamaz.", senderPlayer, 255, 64, 64)
        return
    end
    if utf8.len(content) > config.maxMessageLength then
        outputChatBox("[PM] Mesaj çok uzun.", senderPlayer, 255, 64, 64)
        return
    end

    local limited, waitMs = isRateLimited(senderAccount)
    if limited then
        outputChatBox(string.format("[PM] Yavaş! %dms sonra tekrar deneyin.", waitMs), senderPlayer, 255, 128, 0)
        return
    end

    local mode = payload.mode -- "online" or "account"
    if mode == "online" then
        local receiverPlayer = payload.receiverPlayer
        if not isElement(receiverPlayer) or getElementType(receiverPlayer) ~= "player" then
            outputChatBox("[PM] Hedef oyuncu bulunamadı.", senderPlayer, 255, 64, 64)
            return
        end
        local receiverAccount = getAccountNameForPlayer(receiverPlayer)
        if not receiverAccount then
            outputChatBox("[PM] Hedef oyuncu giriş yapmamış.", senderPlayer, 255, 64, 64)
            return
        end

        -- Save as delivered immediately and notify target
        saveMessage(senderAccount, receiverAccount, content, true)
        deliverToOnline(receiverPlayer, senderAccount, content)
        outputChatBox("[PM] Gönderildi.", senderPlayer, 128, 255, 128)
        return
    elseif mode == "account" then
        local receiverAccount = tostring(payload.receiverAccount or "")
        if receiverAccount == "" then
            outputChatBox("[PM] Alıcı hesap adı gerekli.", senderPlayer, 255, 64, 64)
            return
        end
        local acc = getAccount(receiverAccount)
        if not acc then
            outputChatBox("[PM] Böyle bir hesap yok: " .. receiverAccount, senderPlayer, 255, 64, 64)
            return
        end

        -- If account is online, deliver now; else store undelivered
        local deliveredNow = false
        for _, p in ipairs(getElementsByType("player")) do
            local pAccName = getAccountNameForPlayer(p)
            if pAccName == receiverAccount then
                saveMessage(senderAccount, receiverAccount, content, true)
                deliverToOnline(p, senderAccount, content)
                deliveredNow = true
                break
            end
        end
        if not deliveredNow then
            saveMessage(senderAccount, receiverAccount, content, false)
        end
        outputChatBox("[PM] Gönderildi.", senderPlayer, 128, 255, 128)
        return
    else
        outputChatBox("[PM] Geçersiz gönderim modu.", senderPlayer, 255, 64, 64)
        return
    end
end)

-- Deliver undelivered messages upon player login
addEventHandler("onPlayerLogin", root, function(_, newAccount)
    local player = source
    local accountName = getAccountName(newAccount)
    local undelivered = fetchUndelivered(accountName)
    if undelivered and #undelivered > 0 then
        -- Mark delivered, then send to client
        local ids = {}
        for _, row in ipairs(undelivered) do
            table.insert(ids, row.id)
        end
        markDelivered(ids)
        triggerClientEvent(player, "pm:deliverUndelivered", resourceRoot, undelivered)
    end
end)

-- Also try to deliver when resource starts to already-logged-in players
addEventHandler("onResourceStart", resourceRoot, function()
    if not ensureDatabaseSchema() then
        cancelEvent()
        return
    end
    for _, p in ipairs(getElementsByType("player")) do
        local accName = getAccountNameForPlayer(p)
        if accName then
            local undelivered = fetchUndelivered(accName)
            if undelivered and #undelivered > 0 then
                local ids = {}
                for _, row in ipairs(undelivered) do
                    table.insert(ids, row.id)
                end
                markDelivered(ids)
                triggerClientEvent(p, "pm:deliverUndelivered", resourceRoot, undelivered)
            end
        end
    end
end)

-- Simple commands: /pm <playerName> <message...>  and  /pmacc <accountName> <message...>
addCommandHandler("pm", function(player, cmd, targetName, ...)
    if not isElement(player) then return end
    local senderAccount = getAccountNameForPlayer(player)
    if not senderAccount then
        outputChatBox("[PM] Mesaj göndermek için giriş yapmalısınız.", player, 255, 64, 64)
        return
    end
    local message = table.concat({...}, " ")
    if not targetName or not message or message == "" then
        outputChatBox("Kullanım: /pm [oyuncu_ismi] [mesaj]", player, 255, 255, 0)
        return
    end
    local receiverPlayer = findPlayerByPartialName(targetName)
    if not receiverPlayer then
        outputChatBox("[PM] Oyuncu bulunamadı. Offline için /pmacc kullanın.", player, 255, 64, 64)
        return
    end

    local limited = isRateLimited(senderAccount)
    if limited then
        outputChatBox("[PM] Çok hızlı yolluyorsunuz.", player, 255, 128, 0)
        return
    end

    local receiverAccount = getAccountNameForPlayer(receiverPlayer)
    if not receiverAccount then
        outputChatBox("[PM] Hedef oyuncu giriş yapmamış.", player, 255, 64, 64)
        return
    end
    local content = message
    if utf8.len(content) > config.maxMessageLength then
        outputChatBox("[PM] Mesaj çok uzun.", player, 255, 64, 64)
        return
    end

    saveMessage(senderAccount, receiverAccount, content, true)
    deliverToOnline(receiverPlayer, senderAccount, content)
    outputChatBox("[PM] Gönderildi.", player, 128, 255, 128)
end)

addCommandHandler("pmacc", function(player, cmd, accountName, ...)
    if not isElement(player) then return end
    local senderAccount = getAccountNameForPlayer(player)
    if not senderAccount then
        outputChatBox("[PM] Mesaj göndermek için giriş yapmalısınız.", player, 255, 64, 64)
        return
    end
    local message = table.concat({...}, " ")
    if not accountName or not message or message == "" then
        outputChatBox("Kullanım: /pmacc [hesap_adi] [mesaj]", player, 255, 255, 0)
        return
    end
    local acc = getAccount(accountName)
    if not acc then
        outputChatBox("[PM] Böyle bir hesap yok: " .. tostring(accountName), player, 255, 64, 64)
        return
    end

    local limited = isRateLimited(senderAccount)
    if limited then
        outputChatBox("[PM] Çok hızlı yolluyorsunuz.", player, 255, 128, 0)
        return
    end

    -- If online, deliver now
    local deliveredNow = false
    for _, p in ipairs(getElementsByType("player")) do
        local pAccName = getAccountNameForPlayer(p)
        if pAccName == accountName then
            saveMessage(senderAccount, accountName, message, true)
            deliverToOnline(p, senderAccount, message)
            deliveredNow = true
            break
        end
    end
    if not deliveredNow then
        saveMessage(senderAccount, accountName, message, false)
    end
    outputChatBox("[PM] Gönderildi.", player, 128, 255, 128)
end)
