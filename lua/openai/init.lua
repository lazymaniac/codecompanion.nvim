local Client = require("openai.client")
local config = require("openai.config")
local utils = require("openai.utils.util")
local M = {}

local _client
---@return nil|openai.Client
local function get_client()
  if not _client then
    local secret_key = os.getenv(config.config.api_key)
    if not secret_key then
      vim.notify(
        string.format("Could not find env variable: %s", config.config.api_key),
        vim.log.levels.ERROR
      )
      return nil
    end
    _client = Client.new({
      secret_key = secret_key,
      organization = os.getenv(config.config.org_api_key),
    })
  end
  return _client
end

---@param bufnr nil|integer
---@return nil|openai.Chat
M.buf_get_chat = function(bufnr)
  return require("openai.actions.chat").buf_get_chat(bufnr)
end

M.chat = function()
  local client = get_client()
  if not client then
    return
  end
  local Chat = require("openai.actions.chat")
  local chat = Chat.new({
    client = client,
  })
  vim.api.nvim_win_set_buf(0, chat.bufnr)
  utils.scroll_to_end(0)
  vim.bo[chat.bufnr].filetype = "markdown"
end

local last_edit
---@param context nil|table
---@return nil|openai.Assistant
M.assistant = function(context)
  local client = get_client()
  if not client then
    return
  end

  local Assistant = require("openai.actions.assistant")
  context = context or utils.get_context(vim.api.nvim_get_current_buf())

  last_edit = Assistant.new({
    context = context,
    client = client,
  })

  last_edit:start(function()
    utils.set_dot_repeat("repeat_last_edit")
  end)
end

M.repeat_last_edit = function()
  if last_edit and vim.api.nvim_get_current_buf() == last_edit.bufnr then
    last_edit:start(function()
      utils.set_dot_repeat("repeat_last_edit")
    end)
  end
end

---@param context nil|table
---@return nil|openai.Assistant
M.lsp_assistant = function(context)
  local client = get_client()
  if not client then
    return
  end

  local LSPAssistant = require("openai.actions.lsp_assistant")
  context = context or utils.get_context(vim.api.nvim_get_current_buf())

  return LSPAssistant.new({
    context = context,
    client = client,
  }):start(require("openai.utils.ui").popup)
end

M.commands = function()
  local items = config.config.commands
  local context = utils.get_context(vim.api.nvim_get_current_buf())

  require("openai.utils.ui").select(context, items)
end

M.setup = function()
  config.setup()
end

return M