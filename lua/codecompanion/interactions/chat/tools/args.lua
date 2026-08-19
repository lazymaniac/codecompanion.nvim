local fmt = string.format

-- Names that LLMs habitually reach for when calling a tool. Members of a group
-- are interchangeable: whichever one a tool's schema declares is the name the
-- others are renamed onto, so a model trained against another toolset still
-- lands on the right parameter.
local ALIAS_GROUPS = {
  { "filepath", "path", "file", "file_path", "absolute_path", "filename", "file_name", "target_file" },
  { "query", "pattern", "search", "search_query", "search_pattern", "search_text" },
  { "include_pattern", "glob", "include", "include_glob", "file_pattern" },
  { "content", "contents", "file_text", "new_content" },
  { "start_line", "offset", "start", "from_line", "line_start" },
  { "end_line", "to_line", "line_end" },
  { "max_results", "limit", "count", "max_count", "head_limit" },
  { "oldText", "old_text", "old_string", "old_str", "oldString" },
  { "newText", "new_text", "new_string", "new_str", "newString" },
  { "replaceAll", "replace_all", "all_occurrences" },
  { "severity", "min_severity", "level" },
}

local M = {}

---Whether a value counts as absent
---@param value any
---@return boolean
local function is_missing(value)
  return value == nil or value == vim.NIL
end

---Whether the schema lets this property be null, as `anyOf` nullable types do
---@param property table?
---@return boolean
local function allows_null(property)
  if type(property) ~= "table" then
    return false
  end
  if property.type == "null" then
    return true
  end
  if type(property.type) == "table" and vim.tbl_contains(property.type, "null") then
    return true
  end
  for _, variant in ipairs(property.anyOf or property.oneOf or {}) do
    if type(variant) == "table" and variant.type == "null" then
      return true
    end
  end
  return false
end

---The name from a group that this schema actually declares
---@param properties table
---@param group string[]
---@return string?
local function canonical_name(properties, group)
  for _, name in ipairs(group) do
    if properties[name] ~= nil then
      return name
    end
  end
end

---Bring a loosely typed value in line with the type the schema declares
---@param value any
---@param declared_type string?
---@return any
local function coerce(value, declared_type)
  if declared_type == "integer" or declared_type == "number" then
    if type(value) == "string" and value ~= "" then
      -- Left alone when it isn't a number so the tool can report the bad value
      return tonumber(value) or value
    end
  elseif declared_type == "boolean" then
    if value == "true" then
      return true
    elseif value == "false" then
      return false
    end
  end
  return value
end

---Rename aliased keys onto the names the schema declares and coerce their types
---@param properties table
---@param args table
---@return table
local function normalize_keys(properties, args)
  for _, group in ipairs(ALIAS_GROUPS) do
    local canonical = canonical_name(properties, group)
    if canonical and is_missing(args[canonical]) then
      for _, alias in ipairs(group) do
        if alias ~= canonical and properties[alias] == nil and not is_missing(args[alias]) then
          args[canonical] = args[alias]
          args[alias] = nil
          break
        end
      end
    end
  end

  for name, property in pairs(properties) do
    if not is_missing(args[name]) then
      args[name] = coerce(args[name], property.type)
      -- Arrays of objects carry the same alias problem one level down
      if property.type == "array" and type(property.items) == "table" and type(args[name]) == "table" then
        local item_properties = property.items.properties
        if type(item_properties) == "table" then
          for _, item in ipairs(args[name]) do
            if type(item) == "table" then
              normalize_keys(item_properties, item)
            end
          end
        end
      end
    end
  end

  return args
end

---List every parameter the tool accepts, marking the mandatory ones
---@param properties table
---@param required table<string, boolean>
---@return string
local function describe_parameters(properties, required)
  local names = vim.tbl_keys(properties)
  table.sort(names)
  return table.concat(
    vim.tbl_map(function(name)
      return fmt("`%s`%s", name, required[name] and " (required)" or "")
    end, names),
    ", "
  )
end

---Normalize the arguments from a tool call and check them against its schema
---@param schema table? The `function` table from the tool's schema
---@param args table? The arguments from the LLM's tool call
---@return table args
---@return string? error_message
function M.normalize(schema, args)
  args = args or {}

  local parameters = schema and schema.parameters
  local properties = parameters and parameters.properties
  if type(properties) ~= "table" or vim.tbl_isempty(properties) then
    return args, nil
  end

  args = normalize_keys(properties, args)

  local required = {}
  for _, name in ipairs(parameters.required or {}) do
    required[name] = true
  end

  local missing, unrecognized = {}, {}
  for name in pairs(required) do
    local value = args[name]
    -- Strict schemas mark optional parameters as required but nullable, so a
    -- nullable parameter is satisfied whether it arrives as null or not at all
    if (value == nil or value == vim.NIL) and not allows_null(properties[name]) then
      table.insert(missing, fmt("`%s`", name))
    end
  end
  for name in pairs(args) do
    if properties[name] == nil then
      table.insert(unrecognized, fmt("`%s`", name))
    end
  end

  if #missing == 0 and (#unrecognized == 0 or parameters.additionalProperties == true) then
    -- Tools read an absent value far more reliably than vim.NIL, which is
    -- truthy in Lua and would pass every `if args.x then` guard

    for name, value in pairs(args) do
      if value == vim.NIL then
        args[name] = nil
      end
    end
    return args, nil
  end

  table.sort(missing)
  table.sort(unrecognized)

  local problems = {}
  if #missing > 0 then
    table.insert(problems, fmt("missing required %s", table.concat(missing, ", ")))
  end
  if #unrecognized > 0 then
    table.insert(problems, fmt("does not have %s", table.concat(unrecognized, ", ")))
  end

  return args,
    fmt(
      "The `%s` tool %s. It accepts: %s. Call it again using exactly those parameter names.",
      schema.name or "tool",
      table.concat(problems, ", and "),
      describe_parameters(properties, required)
    )
end

return M
