-- core/log.lua  --  thin wrapper around console.print

local M = {}

local PREFIX = '[SilentRaven] '

M.info = function (msg)
    if console and console.print then
        console.print(PREFIX .. tostring(msg))
    end
end

M.debug = function (settings, msg)
    if settings and settings.debug and console and console.print then
        console.print(PREFIX .. tostring(msg))
    end
end

return M
