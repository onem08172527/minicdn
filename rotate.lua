-- /etc/openresty/lua/handlers/rotate.lua
local svc = require "lib.img_service"

local deg = tonumber(ngx.var[1])
local src = ngx.var.arg_i

if deg == nil or deg < -360 or deg > 360 then
    ngx.status = 400
    ngx.say("invalid degrees")
    return ngx.exit(400)
end

return svc.serve_variant("rotate", deg, nil, src, function(img)
    -- rotate(degrees, r,g,b) is documented. :contentReference[oaicite:7]{index=7}
    local ok, err = img:rotate(deg, 0, 0, 0) -- fill corners with black
    if not ok then return nil, err end
    return true
end)
