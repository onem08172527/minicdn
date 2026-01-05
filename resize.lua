-- /etc/openresty/lua/handlers/resize.lua
local svc = require "lib.img_service"

local w = tonumber(ngx.var[1])
local h = tonumber(ngx.var[2])
local src = ngx.var.arg_i

if not w or not h or w < 1 or h < 1 then
    ngx.status = 400
    ngx.say("invalid size")
    return ngx.exit(400)
end

return svc.serve_variant("resize", w, h, src, function(img)
    -- Exact box while keeping aspect ratio (may crop)
    -- resize_and_crop is in lua-resty-imagick docs :contentReference[oaicite:5]{index=5}
    local ok, err = img:resize_and_crop(w, h)
    if not ok then return nil, err end
    return true
end)
