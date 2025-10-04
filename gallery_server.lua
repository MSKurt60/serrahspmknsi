-- MTA Galeri Sistemi Server Side
local db = dbConnect("sqlite", "gallery.db")

addEventHandler("onResourceStart", resourceRoot, function()
    dbExec(db, [[
        CREATE TABLE IF NOT EXISTS vehicles(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            model INTEGER,
            price INTEGER,
            mileage INTEGER,
            owner TEXT,
            owner_account TEXT,
            purchase_date TEXT,
            first_owner TEXT
        )
    ]])
end)

local galleryVehicles = {
    {411, 150000, 0}, {415, 120000, 0}, {429, 180000, 0}, {541, 130000, 0},
    {480, 90000, 0}, {562, 95000, 0}, {559, 110000, 0}, {506, 170000, 0},
    {451, 250000, 0}, {477, 80000, 0}, {522, 70000, 0}, {521, 75000, 0},
    {587, 85000, 0}, {602, 60000, 0}, {496, 50000, 0},
}

local galleryMarker = createMarker(2150, -1800, 13, "cylinder", 2, 0, 255, 0, 150)
local playerVehicleTimers = {}

addEventHandler("onMarkerHit", galleryMarker, function(player)
    if getElementType(player) == "player" then
        triggerClientEvent(player, "openGalleryPanel", resourceRoot, galleryVehicles)
    end
end)

addEvent("buyGalleryVehicle", true)
addEventHandler("buyGalleryVehicle", resourceRoot, function(vehicleIdx)
    local acc = getPlayerAccount(client)
    if not acc or isGuestAccount(acc) then return end

    local vehData = galleryVehicles[vehicleIdx]
    if not vehData then return end

    local money = getPlayerMoney(client)
    if money < vehData[2] then
        triggerClientEvent(client, "galleryMessage", resourceRoot, "Yetersiz paranız var!")
        return
    end

    takePlayerMoney(client, vehData[2])

    local now = getRealTime()
    local dateStr = string.format("%04d-%02d-%02d %02d:%02d:%02d", now.year+1900, now.month+1, now.monthday, now.hour, now.minute, now.second)
    dbExec(db, "INSERT INTO vehicles (model, price, mileage, owner, owner_account, purchase_date, first_owner) VALUES (?, ?, ?, ?, ?, ?, ?)",
        vehData[1], vehData[2], vehData[3], getPlayerName(client), getAccountName(acc), dateStr, "Server"
    )

    triggerClientEvent(client, "refreshMyVehicles", resourceRoot)
    triggerClientEvent(client, "galleryMessage", resourceRoot, "Araç başarıyla alındı!")
end)

addEvent("getMyVehicles", true)
addEventHandler("getMyVehicles", resourceRoot, function()
    local acc = getPlayerAccount(client)
    if not acc or isGuestAccount(acc) then return end

    local vehicles = {}
    local qh = dbQuery(db, "SELECT * FROM vehicles WHERE owner_account=?", getAccountName(acc))
    local result = dbPoll(qh, -1)
    if result then
        for _, row in ipairs(result) do
            table.insert(vehicles, row)
        end
    end
    triggerClientEvent(client, "receiveMyVehicles", resourceRoot, vehicles)
end)

addEvent("showVehicle", true)
addEventHandler("showVehicle", resourceRoot, function(vehicle_id)
    local acc = getPlayerAccount(client)
    if not acc or isGuestAccount(acc) then return end

    local qh = dbQuery(db, "SELECT * FROM vehicles WHERE id=? AND owner_account=?", vehicle_id, getAccountName(acc))
    local result = dbPoll(qh, -1)
    if result and #result > 0 then
        local data = result[1]
        local tempVeh = getElementData(client, "tempVehicle")
        -- Fixed: Check if tempVeh exists and is a valid element
        if not tempVeh or not isElement(tempVeh) then
            local x, y, z = getElementPosition(client)
            local veh = createVehicle(data.model, x + 3, y, z)
            setElementData(veh, "owner_account", getAccountName(acc))
            setElementData(veh, "vehicle_db_id", data.id)
            setElementData(veh, "mileage", tonumber(data.mileage) or 0)
            warpPedIntoVehicle(client, veh)
            setElementData(client, "tempVehicle", veh)

            -- Timer temizliği
            if playerVehicleTimers[client] then
                if isTimer(playerVehicleTimers[client]) then killTimer(playerVehicleTimers[client]) end
                playerVehicleTimers[client] = nil
            end

            playerVehicleTimers[client] = setTimer(function()
                local curVeh = getElementData(client, "tempVehicle")
                if isElement(curVeh) and getVehicleOccupant(curVeh, 0) == client then
                    local curVehId = getElementData(curVeh, "vehicle_db_id")
                    if curVehId then
                        local mileage = (tonumber(getElementData(curVeh, "mileage")) or 0) + 1
                        setElementData(curVeh, "mileage", mileage)
                        dbExec(db, "UPDATE vehicles SET mileage = ? WHERE id = ?", mileage, curVehId)
                        outputChatBox("[GALERİ] +1 KM eklendi! Toplam KM: "..mileage, client, 255, 255, 0)
                        triggerClientEvent(client, "refreshMyVehicles", resourceRoot)
                    end
                end
            end, 7000, 0)
        else
            outputChatBox("Zaten bir aracınız gösteriliyor!", client, 255, 255, 0)
        end
    end
end)

addEvent("hideVehicle", true)
addEventHandler("hideVehicle", resourceRoot, function()
    local tempVeh = getElementData(client, "tempVehicle")
    if tempVeh and isElement(tempVeh) then
        if playerVehicleTimers[client] then
            if isTimer(playerVehicleTimers[client]) then killTimer(playerVehicleTimers[client]) end
            playerVehicleTimers[client] = nil
        end
        local km = tonumber(getElementData(tempVeh, "mileage")) or 0
        local db_id = getElementData(tempVeh, "vehicle_db_id")
        if db_id then
            dbExec(db, "UPDATE vehicles SET mileage = ? WHERE id = ?", km, db_id)
        end
        destroyElement(tempVeh)
        setElementData(client, "tempVehicle", nil)
        triggerClientEvent(client, "refreshMyVehicles", resourceRoot)
    end
end)

addEventHandler("onVehicleExplode", root, function()
    for player, timer in pairs(playerVehicleTimers) do
        local tempVeh = getElementData(player, "tempVehicle")
        if tempVeh and isElement(tempVeh) and tempVeh == source then
            if isTimer(timer) then killTimer(timer) end
            playerVehicleTimers[player] = nil
            setElementData(player, "tempVehicle", nil)
            local km = tonumber(getElementData(source, "mileage")) or 0
            local db_id = getElementData(source, "vehicle_db_id")
            if db_id then
                dbExec(db, "UPDATE vehicles SET mileage = ? WHERE id = ?", km, db_id)
            end
            triggerClientEvent(player, "refreshMyVehicles", resourceRoot)
            break
        end
    end
end)

addEventHandler("onPlayerQuit", root, function()
    if playerVehicleTimers[source] then
        if isTimer(playerVehicleTimers[source]) then killTimer(playerVehicleTimers[source]) end
        playerVehicleTimers[source] = nil
    end
    local tempVeh = getElementData(source, "tempVehicle")
    if tempVeh and isElement(tempVeh) then
        destroyElement(tempVeh)
    end
end)

addEvent("vehicleAction", true)
addEventHandler("vehicleAction", resourceRoot, function(vehicle_id, action)
    outputChatBox("["..action.."] özelliği henüz eklenmedi.", client, 255, 255, 0)
end)