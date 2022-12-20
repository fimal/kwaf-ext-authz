local typedefs = require "kong.db.schema.typedefs"


local PLUGIN_NAME = "rdwr-kwaf"


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
          { enforcer_service_url = typedefs.url {
              required = true,
              default = "http://waas-enforcer.kwaf.svc.cluster.local" } },
          { enforcer_port = typedefs.port {
              required = true,
              default = 80 } },
          { max_req_bytes = {
                type="number",
                required = true,
                default = 100000 } },
          { connect_timeout = { 
              type = "string",
              default = "250ms",
              required = false } },
          { fail_open = { 
              type = "boolean",
              default = true,
              required = false } },
          { timeout_error_code = { 
              type = "number",
              default = 406,
              required = false } },
        },
        entity_checks = {
          -- add some validation rules across fields
          -- the following is silly because it is always true, since they are both required
          { at_least_one_of = { "enforcer_service_url", "enforcer_port" }, }
        },
      },
    },
  },
}

return schema
