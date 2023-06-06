-- schema.lua
local typedefs = require "kong.db.schema.typedefs"
local PLUGIN_NAME = "rdwr-kwaap"
local schema = {
        name = PLUGIN_NAME,
        fields = {
                -- the 'fields' array is the top-level entry with fields defined by Kong
                { consumer = typedefs.no_consumer },  -- this plugin cannot be configured on a consumer (typical for auth plugins)
                { protocols = typedefs.protocols_http },
                { config = {
                    -- The 'config' record is the custom part of the plugin schema
                    type = "record",
                    fields = {
                    -- a standard defined field (typedef), with some customizations
                        { enforcer_service_address = {
                            type = "string",
                            required = true,
                            default = "waas-enforcer.kwaf.svc.cluster.local", },},
                        { enforcer_service_port = {
                            type = "number",
                            required = true,
                            default = 31012, },},
                        { max_req_bytes = {
                            type="number",
                            required = true,
                            default = 10240, },},
                        { fail_open = {
                            type = "boolean",
                            default = true,
                            required = false, },},
                        { inspection_fail_error_code = {
                            type = "number",
                            default = 406,
                            required = false, },},
                        { inspection_fail_reason = {
                            type = "string",
                            default = "CustomNotAcceptable",
                            required = false, },},
                        { original_content_length_header_name = {
                            type = "string",
                            default = "x-enforcer-original-content-length",
                            required = false, },},
                        { partial_header_name = {
                            type = "string",
                            default = "x-envoy-auth-partial-body",
                            required = false, },},
                        { connect_timeout = {
                            type = "number",
                            default = 1000,
                            required = false, },},
                        { send_timeout = {
                            type = "number",
                            default = 1000,
                            required = false, },},
                        { read_timeout = {
                            type = "number",
                            default = 1000,
                            required = false, },},
                        { keepalive = {
                            type = "boolean",
                            default = true,
                            required = false, },},
                        { pool_size = {
                            type = "number",
                            default = 1000,
                            required = false, },},
                        { keep_alive_timeout = {
                            type = "string",
                            default = "60s",
                            required = false, },},
                    },
                    entity_checks = {
                        -- add some validation rules across fields
                        -- the following is silly because it is always true, since they are both required
                        { at_least_one_of = { "enforcer_service_address", "enforcer_service_port" }, }
                    },
                  },
                },
            },
        }
return schema