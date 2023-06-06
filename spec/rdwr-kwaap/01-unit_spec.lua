local PLUGIN_NAME = "rdwr-kwaap"


-- helper function to validate data against a schema
local validate do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins."..PLUGIN_NAME..".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()


  it("enforcer url and port is required", function()
    local ok, err = validate({
        enforcer_service_url = "example.com"
      })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

end)
