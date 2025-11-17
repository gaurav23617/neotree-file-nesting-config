--- Convert VSCode file nesting config to Neo-tree format
--- This script reads the VSCode config and converts it to Neo-tree Lua format

local json_file = "/tmp/vscode-config.json"

-- Read JSON file
local function read_file(path)
  local file = io.open(path, "r")
  if not file then
    print("Error: Could not open file: " .. path)
    os.exit(1)
  end
  local content = file:read("*all")
  file:close()
  return content
end

-- Simple JSON parser for the specific format we need
local function parse_json(json_str)
  -- Remove comments (// style)
  json_str = json_str:gsub("//[^\n]*\n", "\n")

  -- Find the explorer.fileNesting.patterns object
  local patterns_start = json_str:find('"explorer%.fileNesting%.patterns"%s*:%s*{')
  if not patterns_start then
    print("Error: Could not find explorer.fileNesting.patterns in JSON")
    os.exit(1)
  end

  -- Extract the patterns object
  local depth = 0
  local start_brace = json_str:find("{", patterns_start)
  local current = start_brace
  local end_brace = nil

  while current <= #json_str do
    local char = json_str:sub(current, current)
    if char == "{" then
      depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 0 then
        end_brace = current
        break
      end
    end
    current = current + 1
  end

  if not end_brace then
    print("Error: Could not parse JSON structure")
    os.exit(1)
  end

  local patterns_json = json_str:sub(start_brace, end_brace)

  -- Parse key-value pairs
  local patterns = {}
  -- Match "key": "value" pairs, handling escaped quotes
  for key, value in patterns_json:gmatch('"([^"]+)"%s*:%s*"([^"]*)"') do
    patterns[key] = value
  end

  return patterns
end

-- Convert VSCode glob pattern to Lua pattern
local function glob_to_lua_pattern(glob)
  -- Escape special Lua pattern characters
  local pattern = glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")

  -- Convert glob wildcards to Lua patterns
  pattern = pattern:gsub("%*", "(.*)") -- * becomes (.*)

  -- Add end anchor
  pattern = pattern .. "$"

  return pattern
end

-- Convert VSCode file list to Neo-tree format
local function convert_file_list(file_str)
  local files = {}

  -- Split by comma
  for file in file_str:gmatch("([^,]+)") do
    -- Trim whitespace
    file = file:match("^%s*(.-)%s*$")

    -- Convert to Lua pattern
    local lua_pattern = file:gsub("%.", "%%.") -- Escape dots
    lua_pattern = lua_pattern:gsub("%%1", "%%1") -- Keep %1 as is for capture
    lua_pattern = lua_pattern:gsub("%*", "*") -- Keep * as glob
    lua_pattern = lua_pattern:gsub("*", "%.*") -- Convert * to .*

    -- Re-do it properly
    lua_pattern = file:gsub("%.", "%%.") -- Escape dots
    lua_pattern = lua_pattern:gsub("%*", "%%.*") -- Convert * to .*
    lua_pattern = lua_pattern:gsub("%%%%1", "%%1") -- Fix %1 captures

    table.insert(files, lua_pattern)
  end

  return files
end

-- Check if pattern should have ignore_case flag
local function should_ignore_case(key)
  -- README.* should be case insensitive
  return key:match("^README") ~= nil
end

-- Convert VSCode config to Neo-tree format
local function convert_to_neotree(vscode_patterns)
  local neotree_rules = {}

  for key, value in pairs(vscode_patterns) do
    local pattern = glob_to_lua_pattern(key)
    local files = convert_file_list(value)

    neotree_rules[key] = {
      pattern = pattern,
      files = files,
    }

    if should_ignore_case(key) then
      neotree_rules[key].ignore_case = true
    end
  end

  return neotree_rules
end

-- Sort table by keys
local function sort_by_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end
  table.sort(keys)

  local sorted = {}
  for _, k in ipairs(keys) do
    sorted[k] = tbl[k]
  end

  return sorted
end

-- Serialize Lua table to string
local function serialize_table(tbl, indent_level)
  indent_level = indent_level or 0
  local indent = string.rep("  ", indent_level)
  local next_indent = string.rep("  ", indent_level + 1)

  local lines = {}
  table.insert(lines, "{")

  -- Check if it's an array
  local is_array = true
  local max_index = 0
  for k, _ in pairs(tbl) do
    if type(k) ~= "number" then
      is_array = false
      break
    end
    if k > max_index then
      max_index = k
    end
  end

  if is_array then
    for i = 1, max_index do
      if tbl[i] == nil then
        is_array = false
        break
      end
    end
  end

  if is_array then
    -- Array format
    for _, v in ipairs(tbl) do
      local value_str
      if type(v) == "string" then
        value_str = "'" .. v:gsub("'", "\\'") .. "'"
      elseif type(v) == "table" then
        value_str = serialize_table(v, indent_level + 1)
      else
        value_str = tostring(v)
      end
      table.insert(lines, next_indent .. value_str .. ",")
    end
  else
    -- Object format - sort keys
    local keys = {}
    for k in pairs(tbl) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)

    for _, k in ipairs(keys) do
      local v = tbl[k]
      local key_str = "['" .. k .. "']"
      local value_str

      if type(v) == "string" then
        value_str = "'" .. v:gsub("'", "\\'") .. "'"
      elseif type(v) == "boolean" then
        value_str = tostring(v)
      elseif type(v) == "table" then
        value_str = serialize_table(v, indent_level + 1)
      else
        value_str = tostring(v)
      end

      table.insert(lines, next_indent .. key_str .. " = " .. value_str .. ",")
    end
  end

  table.insert(lines, indent .. "}")
  return table.concat(lines, "\n")
end

-- Main execution
print("Reading VSCode config from: " .. json_file)
local json_content = read_file(json_file)

print("Parsing JSON...")
local vscode_patterns = parse_json(json_content)

print("Found " .. vim.tbl_count(vscode_patterns) .. " patterns")

print("Converting to Neo-tree format...")
local neotree_rules = convert_to_neotree(vscode_patterns)

-- Sort by keys for consistent output
neotree_rules = sort_by_keys(neotree_rules)

-- Generate output files
local init_template = [[
--- Generated by ./build/convert.lua
--- DO NOT EDIT THIS FILE DIRECTLY

local M = {}

M.nesting_rules = %s

return M
-- vim: set nomodifiable :
]]

local readme_template = [[
<h1>Neo-tree File Nesting Config<sup><em> for Neovim</em></sup></h1>

![neotree-file-nesting-config](https://github.com/saifulapm/neotree-file-nesting-config/assets/3833316/88a6e479-e23d-40d2-a44b-b755c43ea666)


A neovim implementation of the [vscode-file-nesting-config](https://github.com/antfu/vscode-file-nesting-config) with [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim).


## Use it

### By Neovim Plugin

```lua
-- lazy.nvim
{
    'nvim-neo-tree/neo-tree.nvim',
    branch = 'v3.x',
    dependencies = {
      -- Others dependencies
      'gaurav23617/neotree-file-nesting-config', -- add plugin as dependency. no need any other config or setup call
    },
    opts = {
      -- recommanded config for better UI
      hide_root_node = true,
      retain_hidden_root_indent = true,
      filesystem = {
        filtered_items = {
          show_hidden_count = false,
          never_show = {
            '.DS_Store',
          },
        },
      },
      default_component_configs = {
        indent = {
          with_expanders = true,
          expander_collapsed = '',
          expander_expanded = '',
        },
      },
      -- others config
    },
    config = function(_, opts)
      -- Adding rules from plugin
      opts.nesting_rules = require('neotree-file-nesting-config').nesting_rules
      require('neo-tree').setup(opts)
    end,
}
```

### Update Manually

If you prefer not using plugin, you can copy rules and add your `neo-tree` config directly. But if you use plugin, you will get updates free.

```lua
-- updated %s
%s
```

## Contributing

The snippet is generated by script, do not edit the README directly.
Instead, go to `build/convert.lua`, make changes and then submit a PR. Thanks!

## Credit & References

- [vscode-file-nesting-config](https://github.com/antfu/vscode-file-nesting-config) - Who created all rules for vscode
]]

print("Generating output files...")
local rules_str = serialize_table(neotree_rules)
local init_output = string.format(init_template, rules_str):gsub('"', "'")
local readme_output = string.format(readme_template, os.date("%Y-%m-%d %H:%M"), rules_str):gsub('"', "'")

-- Write files
vim.fn.writefile(vim.split(init_output, "\n"), "./lua/neotree-file-nesting-config.lua")
vim.fn.writefile(vim.split(readme_output, "\n"), "./README.md")

print("✓ Generated lua/neotree-file-nesting-config.lua")
print("✓ Generated README.md")
print("✓ Conversion complete!")
