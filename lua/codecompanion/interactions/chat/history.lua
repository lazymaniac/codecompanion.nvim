local config = require("codecompanion.config")
local files = require("codecompanion.utils.files")
local log = require("codecompanion.utils.log")

local fn = vim.fn
local uv = vim.uv

local M = {}

local CONSTANTS = {
  INDEX_FILE = "index.json",
  CHAT_DIR = "chats",
}

---Get the history storage directory
---@return string
local function get_history_dir()
  local base = config.interactions.chat.history and config.interactions.chat.history.dir
    or (fn.stdpath("data") .. "/codecompanion/history")
  return base
end

---Get the chats directory
---@return string
local function get_chats_dir()
  return get_history_dir() .. "/" .. CONSTANTS.CHAT_DIR
end

---Get the index file path
---@return string
local function get_index_path()
  return get_history_dir() .. "/" .. CONSTANTS.INDEX_FILE
end

---Ensure the history directory exists
---@return boolean
local function ensure_dir()
  local dir = get_chats_dir()
  if not files.exists(dir) then
    local ok, err = files.create_dir_recursive(dir)
    if not ok then
      log:error("Failed to create history directory: %s", err)
      return false
    end
  end
  return true
end

---Load the index file
---@return table
local function load_index()
  local path = get_index_path()
  if not files.exists(path) then
    return { chats = {} }
  end

  local ok, content = pcall(files.read, path)
  if not ok then
    log:warn("Failed to read history index: %s", content)
    return { chats = {} }
  end

  local ok_decode, data = pcall(vim.json.decode, content)
  if not ok_decode or not data then
    log:warn("Failed to decode history index")
    return { chats = {} }
  end

  return data
end

---Save the index file
---@param index table
---@return boolean
local function save_index(index)
  if not ensure_dir() then
    return false
  end

  local ok, json = pcall(vim.json.encode, index)
  if not ok then
    log:error("Failed to encode history index: %s", json)
    return false
  end

  local ok_write = pcall(files.write_to_path, get_index_path(), json)
  if not ok_write then
    log:error("Failed to write history index")
    return false
  end

  return true
end

---Generate a unique chat ID
---@return string
local function generate_id()
  return string.format("%d_%s", os.time(), string.sub(tostring(math.random()):gsub("0%.", ""), 1, 6))
end

---Get a chat file path by ID
---@param id string
---@return string
local function get_chat_path(id)
  return get_chats_dir() .. "/" .. id .. ".json"
end

---Extract title from messages
---@param messages table
---@return string
local function extract_title(messages)
  for _, msg in ipairs(messages) do
    if msg.role == config.constants.USER_ROLE and msg.content and msg.content ~= "" then
      local title = msg.content:gsub("\n", " "):sub(1, 50)
      if #msg.content > 50 then
        title = title .. "..."
      end
      return title
    end
  end
  return "Untitled Chat"
end

---Save a chat to history
---@param chat CodeCompanion.Chat
---@return string|nil id The saved chat ID or nil on failure
function M.save(chat)
  if not ensure_dir() then
    return nil
  end

  local history_config = config.interactions.chat.history or {}
  if history_config.enabled == false then
    return nil
  end

  local messages = chat.messages or {}
  if #messages == 0 then
    return nil
  end

  local index = load_index()
  local id = chat._history_id or generate_id()
  local now = os.time()

  local chat_data = {
    id = id,
    messages = messages,
    adapter = chat.adapter and chat.adapter.name or nil,
    model = chat.adapter and chat.adapter.schema and chat.adapter.schema.model and chat.adapter.schema.model.default
      or nil,
    settings = chat.settings,
    created_at = nil,
    updated_at = now,
  }

  local existing = vim.iter(index.chats):find(function(c)
    return c.id == id
  end)

  if existing then
    chat_data.created_at = existing.created_at
    existing.title = chat.title or extract_title(messages)
    existing.updated_at = now
    existing.message_count = #messages
  else
    chat_data.created_at = now
    table.insert(index.chats, 1, {
      id = id,
      title = chat.title or extract_title(messages),
      created_at = now,
      updated_at = now,
      message_count = #messages,
      adapter = chat_data.adapter,
    })
  end

  local ok, json = pcall(vim.json.encode, chat_data)
  if not ok then
    log:error("Failed to encode chat data: %s", json)
    return nil
  end

  local ok_write = pcall(files.write_to_path, get_chat_path(id), json)
  if not ok_write then
    log:error("Failed to write chat file")
    return nil
  end

  local max_items = history_config.max_items or 50
  while #index.chats > max_items do
    local removed = table.remove(index.chats)
    if removed then
      pcall(files.delete, get_chat_path(removed.id))
    end
  end

  if not save_index(index) then
    return nil
  end

  chat._history_id = id
  return id
end

---Load a chat from history by ID
---@param id string
---@return table|nil
function M.load(id)
  local path = get_chat_path(id)
  if not files.exists(path) then
    log:warn("Chat not found: %s", id)
    return nil
  end

  local ok, content = pcall(files.read, path)
  if not ok then
    log:error("Failed to read chat file: %s", content)
    return nil
  end

  local ok_decode, data = pcall(vim.json.decode, content)
  if not ok_decode or not data then
    log:error("Failed to decode chat file")
    return nil
  end

  return data
end

---Get the most recent chat from history
---@return table|nil
function M.get_last()
  local index = load_index()
  if #index.chats == 0 then
    return nil
  end

  return M.load(index.chats[1].id)
end

---List all chats in history
---@return table[]
function M.list()
  local index = load_index()
  return index.chats or {}
end

---Delete a chat from history
---@param id string
---@return boolean
function M.delete(id)
  local index = load_index()

  local found_idx = nil
  for i, chat in ipairs(index.chats) do
    if chat.id == id then
      found_idx = i
      break
    end
  end

  if not found_idx then
    return false
  end

  table.remove(index.chats, found_idx)
  pcall(files.delete, get_chat_path(id))

  return save_index(index)
end

---Clear all history
---@return boolean
function M.clear()
  local dir = get_history_dir()
  if files.exists(dir) then
    local ok, err = files.delete(dir)
    if not ok then
      log:error("Failed to clear history: %s", err)
      return false
    end
  end
  return true
end

---Render messages from history with proper formatting
---@param chat CodeCompanion.Chat
---@param messages table[]
local function render_history_messages(chat, messages)
  local folds = require("codecompanion.interactions.chat.ui.folds")

  local reasoning_sections = {}
  local current_reasoning_start = nil

  for _, msg in ipairs(messages) do
    local should_render = msg.role ~= config.constants.SYSTEM_ROLE
      and not (msg.opts and msg.opts.visible == false)

    if should_render then
      if msg.role == config.constants.USER_ROLE then
        chat:add_buf_message({
          role = msg.role,
          content = msg.content or "",
        })

        if current_reasoning_start then
          local end_line = vim.api.nvim_buf_line_count(chat.bufnr) - 3
          if end_line > current_reasoning_start then
            table.insert(reasoning_sections, { start = current_reasoning_start, finish = end_line })
          end
          current_reasoning_start = nil
        end
      elseif msg.role == config.constants.LLM_ROLE then
        if msg.reasoning and msg.reasoning ~= "" then
          local reasoning_content = msg.reasoning
          if type(reasoning_content) == "table" then
            reasoning_content = reasoning_content.content or ""
          end
          if reasoning_content and reasoning_content ~= "" then
            chat:add_buf_message({
              role = msg.role,
              content = reasoning_content,
            }, { type = chat.MESSAGE_TYPES.REASONING_MESSAGE })

            if not current_reasoning_start then
              current_reasoning_start = vim.api.nvim_buf_line_count(chat.bufnr) - #vim.split(reasoning_content, "\n") - 1
            end
          end
        end

        if msg.content and msg.content ~= "" then
          chat:add_buf_message({
            role = msg.role,
            content = msg.content,
          }, { type = chat.MESSAGE_TYPES.LLM_MESSAGE })

          if current_reasoning_start then
            local end_line = vim.api.nvim_buf_line_count(chat.bufnr) - #vim.split(msg.content, "\n") - 2
            if end_line > current_reasoning_start then
              table.insert(reasoning_sections, { start = current_reasoning_start, finish = end_line })
            end
            current_reasoning_start = nil
          end
        end

        if msg.tools and msg.tools.calls then
          for _, tool_call in ipairs(msg.tools.calls) do
            local tool_name = tool_call.name or tool_call.function_name or "tool"
            chat:add_buf_message({
              role = msg.role,
              content = string.format("Using tool: **%s**", tool_name),
            }, { type = chat.MESSAGE_TYPES.TOOL_MESSAGE })
          end
        end
      end
    end
  end

  vim.schedule(function()
    for _, section in ipairs(reasoning_sections) do
      folds:create_reasoning_fold(chat, section.start, section.finish)
    end
  end)
end

---Open a chat from history
---@param id string
---@param opts? { window_opts?: table }
---@return CodeCompanion.Chat|nil
function M.open(id, opts)
  opts = opts or {}
  local data = M.load(id)
  if not data then
    return nil
  end

  local adapters = require("codecompanion.adapters")
  local Chat = require("codecompanion.interactions.chat")

  local adapter
  if data.adapter then
    local adapter_config = config.adapters.http[data.adapter] or config.adapters.acp[data.adapter]
    if adapter_config then
      adapter = adapters.resolve(adapter_config)
      if data.model and adapter.schema and adapter.schema.model then
        adapter.schema.model.default = data.model
      end
    end
  end

  local chat = Chat.new({
    adapter = adapter,
    settings = data.settings,
    auto_submit = false,
    window_opts = opts.window_opts,
    stop_context_insertion = true,
  })

  if not chat then
    return nil
  end

  chat._history_id = id
  chat.messages = data.messages or {}

  local index = load_index()
  local entry = vim.iter(index.chats):find(function(c)
    return c.id == id
  end)
  if entry and entry.title then
    chat:set_title(entry.title)
  end

  render_history_messages(chat, data.messages or {})

  chat:add_buf_message({ role = config.constants.USER_ROLE, content = "" })
  chat.header_line = vim.api.nvim_buf_line_count(chat.bufnr) - 1
  chat.ui:render_headers()
  chat.ui:follow()

  return chat
end

---Open the last chat from history or create a new one
---@param opts? { window_opts?: table }
---@return CodeCompanion.Chat|nil
function M.open_last(opts)
  local last = M.get_last()
  if last then
    return M.open(last.id, opts)
  end
  return nil
end

return M
