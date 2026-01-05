-- /etc/openresty/lua/handlers/crop.lua
local svc = require "lib.img_service"

local w = tonumber(ngx.var[1])
local h = tonumber(ngx.var[2])
local src = ngx.var.arg_i

if not w or not h or w < 1 or h < 1 then
    ngx.status = 400
    ngx.say("invalid size")
    return ngx.exit(400)
end

return svc.serve_variant("crop", w, h, src, function(img)
    -- “Crop” behavior varies by your expectations.
    -- A common approach: resize to fill then crop center.
    -- resize_and_crop provides that in one call. :contentReference[oaicite:6]{index=6}
    local ok, err = img:resize_and_crop(w, h)
    if not ok then return nil, err end
    return true
end)
