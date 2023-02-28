-- handler.lua
local plugin = {
    PRIORITY = 1000, -- set the plugin priority, which determines plugin execution order
    VERSION = "0.1", -- version in X.Y.Z format. Check hybrid-mode compatibility requirements.
}
local kong = kong
local ngx  = ngx

local function read_body()
    local r_body = ""
    local read_length = "*all"
    -- read the body
    ngx.req.read_body()
    r_body = ngx.req.get_body_data()
    if r_body == nil then
        kong.log.debug("get_body_data returned nil, reading from file")
        local file = ngx.req.get_body_file()
        if file then
            file_handle = io.open(file, "rb")
            if not file_handle then
                kong.log.debug("could not obtain file handle")
            else
                kong.log.debug("got file handle")
                req_body = file_handle:read(read_length)
                file_handle:close()
                r_body = req_body
            end
        else
            kong.log.debug("get_body_file returned nil")
        end
    end
    if r_body == nil then
        kong.log.debug("nil body")
    else
        kong.log.debug("body size " .. #r_body)
    end
    return r_body
end
-- runs in the 'access_by_lua_block'
function plugin:access(plugin_conf)
    local enforcer_service_url = plugin_conf.enforcer_service_url
    local enforcer_port = plugin_conf.enforcer_port
    local max_req_bytes = plugin_conf.max_req_bytes
    local fail_open = plugin_conf.fail_open
    local timeout_error_code = plugin_conf.timeout_error_code
    local http = require "resty.http"
    -- get request information
    local r_method = ngx.req.get_method()
    local r_request_uri = ngx.var.request_uri
    local r_headers = ngx.req.get_headers()
    local r_content_length = ngx.var.http_content_length
    local u_service = kong.router.get_service()
    local u_request_uri = r_request_uri
    local u_host = u_service["host"]
    local u_route = kong.router.get_route()
    local url_prefix = kong.request.get_forwarded_prefix()
    -- check if strip path is enabled.
    if u_route["strip_path"] == true then
        u_request_uri = string.gsub(r_request_uri, url_prefix,"/")
        kong.log.debug("stripped request [" .. u_request_uri .. "], original uri [" .. r_request_uri .. "]")
    end
    -- request without body have nil content length
    if r_content_length == nil then
        r_content_length = 0
    else
        r_content_length=tonumber(r_content_length)
    end
    -- read body up to max_enforcer_content_length
    local enforcer_content_length = tonumber(0)
    local max_enforcer_content_length=tonumber(max_req_bytes)
    -- check if the content_length is too big, if so, truncate it
    if tonumber(r_content_length) > max_enforcer_content_length then
        kong.log.debug("request bigger than max_enforcer_content_length (" .. tostring(r_content_length) .. "), will send only max_enforcer_content_length (" .. tostring(max_enforcer_content_length) .. ")")
        enforcer_content_length=max_enforcer_content_length
        r_headers["x-rdwr-partial-body"] = true
    else
        enforcer_content_length=r_content_length
        r_headers["x-rdwr-partial-body"] = false
    end
    r_headers["content-length"] = enforcer_content_length
    r_headers["host"] = u_host
    local r_body = ""
    if r_content_length > 0 then
        r_body = read_body()
    end
    -- truncate body if bigger than max_enforcer_content_length
    if r_content_length > enforcer_content_length then
        r_body = r_body:sub(1, max_enforcer_content_length)
    end
    -- make http connection to enforcer
    local httpc  = http.new()
    local params = {}
    params.method = r_method
    params.body = r_body
    params.headers = r_headers
    params.keepalive = plugin_conf.keepalive
    local i, j = string.find(u_request_uri, '?', 1, true)
    if i ~= nil then
        params.query = string.sub(u_request_uri, i)
        u_request_uri = string.sub(u_request_uri, 1, i-1)
        kong.log.debug("index of ? is=", i, " query is:",params.query, " request uri is: ", u_request_uri)
    end
    local res, err = httpc:request_uri(enforcer_service_url .. ":" .. enforcer_port .. u_request_uri, params)
    kong.log.debug("Request [" .. u_request_uri .. "] and original uri [" .. r_request_uri .. "]")
    kong.log.debug("Original Host: [" .. kong.request.get_host() .. "] Upstream Host [" .. u_host .. "]")
    -- TODO handle fail open
    if not res then
        -- on timeout (this happens both for connect timeout and read timeout. connect timeout may mean the enforcer is not running)
        if err == "timeout" then
            kong.log.debug("timeout connecting to enforcer. fail open = " .. fail_open)
            -- fail open on timeout, comment the following line
            if fail_open == true then
                return
            else
                ngx.exit(timeout_error_code)
            end
        end
        -- on any other error
        kong.log.debug("enforcer request failed: " .. err .. "fail open =" .. fail_open)
        -- to fail open on error connecting to enforcer, comment the following line
        -- this can happen when the enforcer service name is not set correctly (resolution error)
        if fail_open == true then
            return
        else
            ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
    end
    -- At this point, the entire request / response is complete and the connection
    -- will be closed or back on the connection pool.
    -- The `res` table contains the expeected `status`, `headers` and `body` fields.
    local s_status = res.status
    local s_headers = res.headers
    local s_body   = res.body
    if s_status == ngx.HTTP_FORBIDDEN then
        ngx.status = s_status
        for k, v in pairs(s_headers) do
            ngx.header[k] = v
        end
        ngx.say(s_body)
        return
    else
        -- pass the request onward to the original destination
        return
    end
end
-- return our plugin object
return plugin