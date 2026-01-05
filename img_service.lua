-- /etc/openresty/lua/lib/img_service.lua
local http  = require "resty.http"
local redis = require "resty.redis"
local imagick = require "resty.imagick"  -- lua-resty-imagick (ImageMagick bindings)

local _M = {}

-- ====== CONFIG ======
local REDIS_HOST = os.getenv("REDIS_HOST") or "127.0.0.1"
local REDIS_PORT = tonumber(os.getenv("REDIS_PORT") or "6379")
local REDIS_DB   = tonumber(os.getenv("REDIS_DB") or "0")
local REDIS_TTL  = tonumber(os.getenv("REDIS_TTL") or "86400") -- 24h

-- WebP options can vary by imagick bindings; keep it simple (format only).
-- You can extend with quality controls if your binding supports it.
local WEBP_MIME = "image/webp"

-- ====== HELPERS ======

local function redis_conn()
    local r = redis:new()
    r:set_timeout(1500)

    local ok, err = r:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        return nil, "redis connect failed: " .. (err or "unknown")
    end

    if REDIS_DB ~= 0 then
        local ok2, err2 = r:select(REDIS_DB)
        if not ok2 then
            return nil, "redis select failed: " .. (err2 or "unknown")
        end
    end

    return r
end

local function redis_keepalive(r)
    if not r then return end
    -- 60s idle, pool size 200
    r:set_keepalive(60000, 200)
end

local function is_http_url(u)
    return type(u) == "string" and (u:match("^https?://") ~= nil)
end

local function basename_from_url(url)
    -- Strip query/fragment and take last path segment
    local nofrag = url:gsub("#.*$", "")
    local noqs   = nofrag:gsub("%?.*$", "")
    local name   = noqs:match("([^/]+)$") or "image"
    if name == "" then name = "image" end

    -- replace extension with .webp (keep same "filename" concept)
    name = name:gsub("%.[%w]+$", "") .. ".webp"
    return name
end

local function cache_key(op, a, b, src)
    -- Use a deterministic key; include full source URL
    return table.concat({ "img", op, tostring(a or ""), tostring(b or ""), src }, "|")
end

local function fetch_external(url)
    local hc = http.new()
    hc:set_timeout(4000)

    local res, err = hc:request_uri(url, {
        method = "GET",
        ssl_verify = false,          -- set true if you manage CA trust properly
        headers = {
            ["User-Agent"] = "1img.tr (OpenResty)",
            ["Accept"] = "*/*",
        }
    })

    if not res then
        return nil, "fetch failed: " .. (err or "unknown")
    end
    if res.status < 200 or res.status >= 300 then
        return nil, "fetch HTTP " .. res.status
    end
    if not res.body or #res.body == 0 then
        return nil, "empty body"
    end
    return res.body
end

local function imagick_load(blob)
    -- Most builds (kwanhur/lua-resty-imagick) support load_image_from_blob(blob) :contentReference[oaicite:1]{index=1}
    if imagick.load_image_from_blob then
        local img, err = imagick.load_image_from_blob(blob)
        if not img then
            return nil, "imagick load_image_from_blob failed: " .. (err or "unknown")
        end
        return img
    end

    -- Fallback for builds that only support load_image(filename) (some OPM descriptions emphasize this) :contentReference[oaicite:2]{index=2}
    -- Write to a temp file, then load by filename.
    local tmp = "/tmp/img-" .. ngx.worker.pid() .. "-" .. ngx.now() .. ".bin"
    local f, ferr = io.open(tmp, "wb")
    if not f then
        return nil, "tempfile open failed: " .. (ferr or "unknown")
    end
    f:write(blob)
    f:close()

    local img, err = imagick.load_image(tmp)
    os.remove(tmp)

    if not img then
        return nil, "imagick load_image(tmp) failed: " .. (err or "unknown")
    end
    return img
end


local function to_webp_blob(img)
    -- set_format + get_blob are part of lua-resty-imagick docs :contentReference[oaicite:1]{index=1}
    local ok, err = img:set_format("webp")
    if not ok then
        return nil, "set_format(webp) failed: " .. (err or "unknown")
    end

    local out = img:get_blob()
    if not out or #out == 0 then
        return nil, "get_blob returned empty"
    end
    return out
end

-- ====== PUBLIC API ======

function _M.serve_variant(op, p1, p2, src_url, transform_fn)
    if not is_http_url(src_url) then
        ngx.status = 400
        ngx.say("missing/invalid i= (must be http/https url)")
        return ngx.exit(400)
    end

    local key = cache_key(op, p1, p2, src_url)
    local filename = basename_from_url(src_url)

    -- 1) Try Redis cache
    local r, err = redis_conn()
    if not r then
        ngx.log(ngx.ERR, err)
    else
        local cached, gerr = r:get(key)
        if cached and cached ~= ngx.null then
            ngx.header["Content-Type"] = WEBP_MIME
            ngx.header["Content-Disposition"] = 'inline; filename="' .. filename .. '"'
            ngx.header["Cache-Control"] = "public, max-age=31536000, immutable"
            ngx.print(cached)
            redis_keepalive(r)
            return ngx.exit(200)
        end
    end

    -- 2) Fetch external
    local src_blob, ferr = fetch_external(src_url)
    if not src_blob then
        if r then redis_keepalive(r) end
        ngx.status = 502
        ngx.say(ferr)
        return ngx.exit(502)
    end

    -- 3) Process with imagick
    local img, ierr = imagick_load(src_blob)
    if not img then
        if r then redis_keepalive(r) end
        ngx.status = 415
        ngx.say(ierr)
        return ngx.exit(415)
    end

    local ok_t, terr = transform_fn(img)
    if not ok_t then
        if r then redis_keepalive(r) end
        ngx.status = 400
        ngx.say("transform failed: " .. (terr or "unknown"))
        return ngx.exit(400)
    end

    local out_blob, oerr = to_webp_blob(img)
    if not out_blob then
        if r then redis_keepalive(r) end
        ngx.status = 500
        ngx.say(oerr)
        return ngx.exit(500)
    end

    -- 4) Save to Redis
    if r then
        local ok_set, serr = r:set(key, out_blob)
        if ok_set then
            r:expire(key, REDIS_TTL)
        else
            ngx.log(ngx.ERR, "redis set failed: ", serr)
        end
        redis_keepalive(r)
    end

    -- 5) Respond
    ngx.header["Content-Type"] = WEBP_MIME
    ngx.header["Content-Disposition"] = 'inline; filename="' .. filename .. '"'
    ngx.header["Cache-Control"] = "public, max-age=31536000, immutable"
    ngx.print(out_blob)
    return ngx.exit(200)
end

function _M.purge_variant(op, p1, p2, src_url)
    if not is_http_url(src_url) then
        ngx.status = 400
        ngx.say("missing/invalid i=")
        return ngx.exit(400)
    end

    local key = cache_key(op, p1, p2, src_url)
    local r, err = redis_conn()
    if not r then
        ngx.status = 500
        ngx.say(err)
        return ngx.exit(500)
    end

    local n, derr = r:del(key)
    redis_keepalive(r)

    ngx.header["Content-Type"] = "application/json"
    ngx.say(string.format('{"deleted":%d,"key":"%s"}', tonumber(n or 0), key))
    return ngx.exit(200)
end

return _M
