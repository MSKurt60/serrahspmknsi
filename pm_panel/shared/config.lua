local config = {
    databaseFile = "pm_panel.db",
    rateLimitMs = 1500,
    maxMessageLength = 256,
    historyLimit = 50,
}

function getPmConfig()
    return config
end
