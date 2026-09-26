--[[--
Safe, user-facing summaries for request failures.

Transport errors and server response bodies can contain URLs, echoed input, or
other private details. The UI shows only these classified summaries, never raw
request strings, credentials, or arbitrary response text.
]]

local _ = require("gettext")

local Errors = {}

function Errors.describe(err, code)
    code = tonumber(code)
    if code == 401 then
        return _("Coppice rejected this device credential. Pair the device again.")
    elseif code == 403 then
        return _("Coppice denied this request. Check the device permissions.")
    elseif code == 404 then
        return _("Coppice could not find that book or reading position.")
    elseif code == 409 then
        return _("Coppice found conflicting data. Review the link or annotation before retrying.")
    elseif code == 429 then
        return _("Coppice is receiving too many requests. Wait a moment and try again.")
    elseif code and code >= 500 and code < 600 then
        return _("Coppice is temporarily unavailable. Try again later.")
    end

    local message = type(err) == "string" and err:lower() or ""
    if message:find("timeout", 1, true)
            or message:find("timed out", 1, true) then
        return _("The request timed out. Check the connection and try again.")
    elseif message:find("closed", 1, true)
            or message:find("refused", 1, true)
            or message:find("unreachable", 1, true)
            or message:find("host not found", 1, true)
            or message:find("name or service not known", 1, true)
            or message:find("network", 1, true) then
        return _("Could not reach Coppice. Check Wi-Fi and the server address.")
    elseif message:find("ssl", 1, true) or message:find("certificate", 1, true) then
        return _("Could not establish an HTTPS connection. Check the server address and TLS support.")
    end
    return _("The request failed. Check the connection and Coppice server.")
end

return Errors
