-- /etc/openresty/lua/handlers/purge.lua
local svc = require "lib.img_service"

local op = ngx.var[1]         -- resize|crop|rotate
local tail = ngx.var[2]       -- e.g. 200x200 or 90
local src = ngx.var.arg_i

if op == "resize" or op == "crop" then
    local w, h = tail:match("^(%d+)x(%d+)$")
    w, h = tonumber(w), tonumber(h)
    return svc.purge_variant(op, w, h, src)
elseif op == "rotate" then
    local deg = tonumber(tail)
    return svc.purge_variant(op, deg, nil, src)
else
    ngx.status = 400
    ngx.say("invalid purge op")
    return ngx.exit(400)
end
