-- handler.lua
local plugin = {
    PRIORITY = 1000, -- set the plugin priority, which determines plugin execution order
    VERSION = "1.14.0", -- version in X.Y.Z format. Check hybrid-mode compatibility requirements.
}
local kong = kong
local ngx  = ngx
local ngx_req = ngx.req
local ngx_var = ngx.var

local function read_body()
    local r_body = ""
    local read_length = "*all"
    -- read the body
    ngx_req.read_body()
    local r_body = ngx_req.get_body_data()
    if r_body == nil then
        kong.log.debug("get_body_data returned nil, reading from file")
        local file = ngx_req.get_body_file()
        if file then
            local file_handle = io.open(file, "rb")
            if not file_handle then
                kong.log.debug("could not obtain file handle")
            else
                kong.log.debug("got file handle")
                local req_body = file_handle:read(read_length)
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
    local enforcer_service_address = plugin_conf.enforcer_service_address
    local enforcer_service_port = plugin_conf.enforcer_service_port
    local max_req_bytes = plugin_conf.max_req_bytes
    local fail_open = plugin_conf.fail_open
    local inspection_fail_error_code = (tonumber(plugin_conf.inspection_fail_error_code)) or 406
    local inspection_fail_reason = plugin_conf.inspection_fail_reason or ""
    local original_content_length_header_name=tostring(plugin_conf.original_content_length_header_name)
    local partial_header_name=tostring(plugin_conf.partial_header_name)
    local connect_timeout = tonumber(plugin_conf.connect_timeout)
    local send_timeout = tonumber(plugin_conf.send_timeout)
    local read_timeout = tonumber(plugin_conf.read_timeout)
    local pool_size = plugin_conf.pool_size
    local keep_alive_timeout = plugin_conf.keep_alive_timeout
    --local lua_backlog = ngx_var.lua_backlog
    local kwaf_fail_close = false
    if fail_open then
        kwaf_fail_close = (fail_open ~= "false") or false
    end

    local http = require "resty.http"
    -- get request information
    local r_method = ngx_req.get_method()
    local r_request_uri = ngx_var.request_uri
    local r_headers = ngx_req.get_headers()
    local r_content_length = ngx_var.http_content_length
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
    local enforcer_content_length = tonumber("0")
    local max_enforcer_content_length = tonumber(max_req_bytes)
    -- check if the content_length is too big, if so, truncate it
    if tonumber(r_content_length) > max_enforcer_content_length then
        kong.log.debug("request bigger than max_enforcer_content_length (" .. tostring(r_content_length) .. "), will send only max_enforcer_content_length (" .. tostring(max_enforcer_content_length) .. ")")
        enforcer_content_length = max_enforcer_content_length
        r_headers[partial_header_name] = "true"
        r_headers[original_content_length_header_name] = r_content_length
    else
        enforcer_content_length=r_content_length
        r_headers[partial_header_name] = "false"
    end
    r_headers["content-length"] = tostring(enforcer_content_length)
    r_headers["host"] = tostring(u_host)
    local r_body = ""
    if r_content_length > 0 then
        r_body = read_body()
    end
    -- truncate body if bigger than max_enforcer_content_length
    if r_content_length > enforcer_content_length then
        r_body = r_body:sub(1, max_enforcer_content_length)
    end
    -- make http connection to enforcer
    local httpc = http.new()
    kong.log.debug("setting timeouts: connect_timeout = " .. tostring(connect_timeout))
    httpc:set_timeouts(connect_timeout, send_timeout, read_timeout)
    local params = {}
    params.method = r_method
    params.body = r_body
    params.headers = r_headers
    params.keepalive = true
    params.query  = ngx_var.query_string
    local i, j = string.find(u_request_uri, '?', 1, true)
    if i ~= nil then
        params.query = string.sub(u_request_uri, i)
        u_request_uri = string.sub(u_request_uri, 1, i-1)
        kong.log.debug("index of ? is=", i, " query is:",params.query, " request uri is: ", u_request_uri)
    end
    local res, err = httpc:request_uri("http://" .. enforcer_service_address .. ":" .. enforcer_service_port .. u_request_uri, params)
    kong.log.debug("Request to enforcer [" .. u_request_uri .. "] and original uri [" .. r_request_uri .. "]")
    kong.log.debug("Original Host: [" .. kong.request.get_host() .. "] Upstream Host [" .. u_host .. "]")
    if not res then
        kong.log.debug("enforcer request failed ")
        -- on timeout (this happens both for connect timeout and read timeout. connect timeout may mean the enforcer is not running)
        if err == "timeout" then
            kong.log.debug("timeout connecting to enforcer. fail open = " .. tostring(fail_open))
            -- fail open on timeout, comment the following line
            if kwaf_fail_close == true then
                return
            else
                ngx.status= inspection_fail_error_code
                ngx.say(inspection_fail_reason)
                ngx.exit(ngx.HTTP_OK)
            end
        end
        -- on any other error
        kong.log.debug("enforcer request failed: " .. err .. " fail open =" .. tostring(fail_open))
        -- to fail open on error connecting to enforcer, comment the following line
        -- this can happen when the enforcer service name is not set correctly (resolution error)
        if kwaf_fail_close == true then
            return
        else
            ngx.status= inspection_fail_error_code
            ngx.say(inspection_fail_reason)
            ngx.exit(ngx.HTTP_OK)
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