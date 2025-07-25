--=============================================================================
-- Chat Memory System - Handles long conversation history with summarization
--=============================================================================

local Path = require("plenary.path")
local adapters = require("codecompanion.adapters")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local util_hash = require("codecompanion.utils.hash")

local fmt = string.format

-- Memory persistence constants
local MEMORY_DIR = vim.fn.stdpath("data") .. "/codecompanion/memory"

---@class CodeCompanion.Chat.Memory
---@field chat CodeCompanion.Chat Reference to the chat instance
---@field memory_entries table Array of memory entries (summaries)
---@field max_context_ratio number Maximum context usage before triggering summarization (0.8 = 80%)
---@field min_messages_to_summarize number Minimum messages needed before summarization
---@field messages_per_summary number Number of messages to include in each summary
---@field memory_id string|nil Unique identifier for this chat's memory file
---@field memory_file_path string|nil Path to the memory persistence file
local Memory = {}
Memory.__index = Memory

-- Memory entry structure
---@class CodeCompanion.Chat.Memory.Entry
---@field summary string The summarized content
---@field original_count number Number of original messages this summary represents
---@field timestamp number When this summary was created
---@field start_cycle number The cycle number this summary starts from
---@field end_cycle number The cycle number this summary ends at
---@field preserved_messages table Any important messages that were preserved

---Generate a memory ID for a chat based on its initial context
---@param chat CodeCompanion.Chat
---@return string
local function generate_memory_id(chat)
  -- Use first user message + adapter name to generate a stable ID
  local first_user_msg = ""
  for _, message in ipairs(chat.messages or {}) do
    if message.role == config.constants.USER_ROLE and message.content then
      first_user_msg = message.content:sub(1, 200) -- First 200 chars
      break
    end
  end

  local chat_context = {
    first_message = first_user_msg,
    adapter = chat.adapter and chat.adapter.name or "unknown",
    timestamp = os.date("%Y%m%d"),
  }

  return util_hash.hash(chat_context)
end

---Get the memory file path for a given memory ID
---@param memory_id string
---@return string
local function get_memory_file_path(memory_id)
  return MEMORY_DIR .. "/" .. memory_id .. ".json"
end

---Ensure the memory directory exists
local function ensure_memory_dir()
  local dir = Path:new(MEMORY_DIR)
  if not dir:exists() then
    dir:mkdir({ parents = true })
    log:debug("[Memory] Created memory directory: %s", MEMORY_DIR)
  end
end

---Create a new Memory instance
---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.Memory
function Memory.new(chat)
  local memory_id = generate_memory_id(chat)
  local memory_file_path = get_memory_file_path(memory_id)

  local self = setmetatable({
    chat = chat,
    memory_entries = {},
    max_context_ratio = 0.75, -- Trigger summarization at 75% context usage
    min_messages_to_summarize = 8, -- Minimum messages before considering summarization
    messages_per_summary = 6, -- Number of messages to include in each summary batch
    summarizer = nil, -- Will be initialized when needed
    memory_id = memory_id,
    memory_file_path = memory_file_path,
  }, Memory)

  -- Try to load existing memory
  self:load_memory()

  log:debug("[Memory] Initialized memory system for chat %d (ID: %s)", chat.id, memory_id)
  return self
end

---Estimate token count for a message (rough approximation)
---@param message table The message to estimate tokens for
---@return number Estimated token count
local function estimate_message_tokens(message)
  if not message.content or type(message.content) ~= "string" then
    return 0
  end

  -- Rough approximation: ~4 characters per token for English
  -- Add some overhead for role, formatting, etc.
  local base_tokens = math.ceil(#message.content / 4)
  local role_overhead = 10 -- Overhead for role, formatting, etc.

  return base_tokens + role_overhead
end

---Estimate total token count for messages array
---@param messages table Array of messages
---@return number Estimated token count
local function estimate_total_tokens(messages)
  local total = 0
  for _, message in ipairs(messages) do
    total = total + estimate_message_tokens(message)
  end
  return total
end

---Get the context limit for the current adapter
---@return number Context limit in tokens
function Memory:get_context_limit()
  -- Try to get max_tokens from adapter schema
  local adapter = self.chat.adapter
  if adapter and adapter.schema and adapter.schema.max_tokens then
    local max_tokens = adapter.schema.max_tokens.default
    if type(max_tokens) == "function" then
      max_tokens = max_tokens(adapter)
    end
    if type(max_tokens) == "number" then
      -- Return the input context limit (total context - max output tokens)
      -- Most models reserve ~25% for output, so input context is ~75%
      return math.floor(max_tokens * 3) -- Conservative estimate of input context
    end
  end

  -- Fallback to conservative default
  return 8000
end

---Check if the current conversation is approaching context limits
---@return boolean, number Whether summarization is needed, current token estimate
function Memory:should_summarize()
  local messages = self.chat.messages
  local message_count = #messages

  -- Don't summarize if we don't have enough messages
  if message_count < self.min_messages_to_summarize then
    return false, 0
  end

  -- Estimate current token usage
  local estimated_tokens = estimate_total_tokens(messages)
  local context_limit = self:get_context_limit()
  local usage_ratio = estimated_tokens / context_limit

  log:debug("[Memory] Token usage: %d/%d (%.1f%%)", estimated_tokens, context_limit, usage_ratio * 100)

  -- Trigger summarization if we exceed the ratio threshold
  return usage_ratio > self.max_context_ratio, estimated_tokens
end

---Check if a message should be preserved during summarization
---@param message table The message to check
---@return boolean Whether to preserve this message
local function should_preserve_message(message)
  -- Always preserve system messages
  if message.role == config.constants.SYSTEM_ROLE then
    return true
  end

  -- Preserve tool-related messages
  if message.opts then
    -- Tool outputs and references
    if message.opts.tag or message.opts.reference or message.opts.tool then
      return true
    end

    -- Recent pinned content
    if message.opts.pinned then
      return true
    end
  end

  -- Preserve tool calls and responses
  if message.tool_calls or (message.role == "tool") then
    return true
  end

  return false
end

---Get or create summarizer instance
---@return CodeCompanion.Chat.Summarizer
function Memory:get_summarizer()
  if not self.summarizer then
    local Summarizer = require("codecompanion.strategies.chat.summarizer")
    self.summarizer = Summarizer.new(self.chat.adapter)
  end
  return self.summarizer
end

---Create a fallback summary when LLM summarization fails
---@param messages table Array of messages to summarize
---@param context? table Additional context
---@return string Fallback summary
local function create_fallback_summary(messages, context)
  local summary_parts = {}
  local user_messages = 0
  local assistant_messages = 0
  local tool_messages = 0

  local topics = {}
  local recent_content = {}

  -- Analyze message content for basic summary
  for i, message in ipairs(messages) do
    if message.role == config.constants.USER_ROLE then
      user_messages = user_messages + 1
      if message.content then
        -- Extract potential topics
        local content = message.content:lower()
        if content:match("implement") or content:match("create") or content:match("build") then
          table.insert(topics, "implementation")
        elseif content:match("explain") or content:match("how") or content:match("what") then
          table.insert(topics, "explanation")
        elseif content:match("fix") or content:match("debug") or content:match("error") then
          table.insert(topics, "debugging")
        elseif content:match("test") or content:match("run") then
          table.insert(topics, "testing")
        end

        -- Keep recent content snippets
        if i > #messages - 3 then
          table.insert(recent_content, message.content:sub(1, 100))
        end
      end
    elseif message.role == config.constants.LLM_ROLE then
      assistant_messages = assistant_messages + 1
    elseif message.role == "tool" then
      tool_messages = tool_messages + 1
    end
  end

  -- Build fallback summary
  table.insert(
    summary_parts,
    fmt("Conversation segment with %d user messages, %d assistant responses", user_messages, assistant_messages)
  )

  if tool_messages > 0 then
    table.insert(summary_parts, fmt("Included %d tool interactions", tool_messages))
  end

  if #topics > 0 then
    local unique_topics = {}
    for _, topic in ipairs(topics) do
      unique_topics[topic] = true
    end
    table.insert(summary_parts, fmt("Topics discussed: %s", table.concat(vim.tbl_keys(unique_topics), ", ")))
  end

  if context and context.start_cycle and context.end_cycle then
    table.insert(summary_parts, fmt("Covered cycles %d-%d", context.start_cycle, context.end_cycle))
  end

  return table.concat(summary_parts, ". ")
end

---Perform summarization of old messages (async with fallback)
---@param callback? function Optional callback when summarization is complete
---@return boolean Whether summarization was initiated or completed synchronously
function Memory:summarize_messages(callback)
  local messages = self.chat.messages

  if #messages < self.min_messages_to_summarize then
    log:debug("[Memory] Not enough messages for summarization (%d < %d)", #messages, self.min_messages_to_summarize)
    if callback then
      callback(false)
    end
    return false
  end

  -- Find the split point - preserve recent messages and important ones
  local preserve_recent_count = math.max(4, math.floor(#messages * 0.25)) -- Preserve at least 4 or 25% of messages
  local summarize_end = #messages - preserve_recent_count

  if summarize_end < self.messages_per_summary then
    log:debug("[Memory] Not enough messages to summarize after preserving recent ones")
    if callback then
      callback(false)
    end
    return false
  end

  -- Split messages to summarize vs preserve
  local to_summarize = {}
  local preserved = {}
  local current_cycle_start = messages[1].cycle or 1
  local current_cycle_end = current_cycle_start

  for i = 1, #messages do
    local message = messages[i]
    current_cycle_end = math.max(current_cycle_end, message.cycle or current_cycle_end)

    if i <= summarize_end and not should_preserve_message(message) then
      table.insert(to_summarize, message)
    else
      table.insert(preserved, message)
    end
  end

  if #to_summarize < self.messages_per_summary then
    log:debug("[Memory] Not enough messages to summarize after filtering preserved ones")
    if callback then
      callback(false)
    end
    return false
  end

  log:debug("[Memory] Summarizing %d messages, preserving %d messages", #to_summarize, #preserved)

  -- Create context for summarization
  local context = {
    start_cycle = current_cycle_start,
    end_cycle = current_cycle_end,
    chat_id = self.chat.id,
  }

  -- Try async summarization first, fallback to sync
  local summarizer = self:get_summarizer()

  local function complete_summarization(summary)
    -- Create memory entry
    local memory_entry = {
      summary = summary,
      original_count = #to_summarize,
      timestamp = os.time(),
      start_cycle = current_cycle_start,
      end_cycle = math.floor((current_cycle_start + current_cycle_end) / 2),
      preserved_messages = {},
    }

    table.insert(self.memory_entries, memory_entry)

    -- Replace chat messages with preserved ones plus a memory reference
    local memory_reference = {
      role = config.constants.SYSTEM_ROLE,
      content = fmt(
        "[MEMORY] Previous conversation summary (%d messages from cycles %d-%d): %s",
        memory_entry.original_count,
        memory_entry.start_cycle,
        memory_entry.end_cycle,
        summary
      ),
      opts = {
        tag = "memory_summary",
        memory_entry_id = #self.memory_entries,
      },
    }

    -- Build new messages array: memory reference + preserved messages
    local new_messages = { memory_reference }
    vim.list_extend(new_messages, preserved)

    -- Replace the chat's messages
    self.chat.messages = new_messages

    log:info("[Memory] Summarized %d messages into memory. Chat now has %d messages.", #to_summarize, #new_messages)

    -- Save memory to persistent storage
    self:save_memory()

    if callback then
      callback(true)
    end
    return true
  end

  -- Try async summarization if we have time
  if callback then
    summarizer:summarize(to_summarize, context, function(summary, error_msg)
      if summary then
        vim.schedule(function()
          complete_summarization(summary)
        end)
      else
        vim.schedule(function()
          log:warn("[Memory] Async summarization failed (%s), using fallback", error_msg or "unknown")
          local fallback_summary = create_fallback_summary(to_summarize, context)
          complete_summarization(fallback_summary)
        end)
      end
    end)
    return true -- Initiated async summarization
  else
    -- Synchronous fallback for immediate summarization
    local fallback_summary = create_fallback_summary(to_summarize, context)
    return complete_summarization(fallback_summary)
  end
end

---Get all memory entries
---@return table Array of memory entries
function Memory:get_memory_entries()
  return vim.deepcopy(self.memory_entries)
end

---Get memory statistics
---@return table Statistics about the memory system
function Memory:get_stats()
  local current_tokens = estimate_total_tokens(self.chat.messages)
  local context_limit = self:get_context_limit()

  return {
    memory_entries = #self.memory_entries,
    current_messages = #self.chat.messages,
    estimated_tokens = current_tokens,
    context_limit = context_limit,
    context_usage_percent = math.floor((current_tokens / context_limit) * 100),
    should_summarize = self:should_summarize(),
  }
end

---Check and potentially trigger automatic summarization
---@return boolean Whether summarization occurred
function Memory:check_and_summarize()
  local should_summarize, token_count = self:should_summarize()

  if should_summarize then
    log:info("[Memory] Context limit approaching (%d tokens), triggering summarization", token_count)
    return self:summarize_messages()
  end

  return false
end

---Save memory entries to persistent storage
---@return boolean Success status
function Memory:save_memory()
  if not self.memory_id or #self.memory_entries == 0 then
    return true -- Nothing to save
  end

  ensure_memory_dir()

  local memory_data = {
    version = 1,
    memory_id = self.memory_id,
    created_at = os.time(),
    last_updated = os.time(),
    adapter_name = self.chat.adapter and self.chat.adapter.name or "unknown",
    entries = self.memory_entries,
    metadata = {
      total_original_messages = vim.tbl_map(function(entry)
        return entry.original_count
      end, self.memory_entries),
      earliest_cycle = #self.memory_entries > 0 and math.min(unpack(vim.tbl_map(function(entry)
        return entry.start_cycle
      end, self.memory_entries))) or 0,
      latest_cycle = #self.memory_entries > 0 and math.max(unpack(vim.tbl_map(function(entry)
        return entry.end_cycle
      end, self.memory_entries))) or 0,
    },
    -- Include branch data if available
    branches = self.chat.branch_manager and self.chat.branch_manager:export_branches() or nil,
  }

  local memory_file = Path:new(self.memory_file_path)

  local success, err = pcall(function()
    memory_file:write(vim.json.encode(memory_data), "w")
  end)

  if not success then
    log:error("[Memory] Failed to save memory to %s: %s", self.memory_file_path, err)
    return false
  end

  log:debug("[Memory] Saved %d memory entries to %s", #self.memory_entries, self.memory_file_path)
  return true
end

---Load memory entries from persistent storage
---@return boolean Success status
function Memory:load_memory()
  if not self.memory_id then
    return false
  end

  local memory_file = Path:new(self.memory_file_path)
  if not memory_file:exists() then
    log:debug("[Memory] No existing memory file found at %s", self.memory_file_path)
    return true -- Not an error, just no existing memory
  end

  local success, memory_content = pcall(function()
    return memory_file:read()
  end)

  if not success then
    log:error("[Memory] Failed to read memory file %s: %s", self.memory_file_path, memory_content)
    return false
  end

  local memory_data
  success, memory_data = pcall(vim.json.decode, memory_content)

  if not success then
    log:error("[Memory] Failed to parse memory file %s: %s", self.memory_file_path, memory_data)
    return false
  end

  -- Validate memory data structure
  if not memory_data.entries or type(memory_data.entries) ~= "table" then
    log:warn("[Memory] Invalid memory data structure in %s", self.memory_file_path)
    return false
  end

  -- Load the memory entries
  self.memory_entries = memory_data.entries

  -- Restore branch data if available and branching is enabled
  if memory_data.branches and self.chat.branch_manager then
    self.chat.branch_manager:import_branches(memory_data.branches)
    log:debug("[Memory] Restored branch data from persistent storage")
  end

  -- Add memory reference messages to chat if we have entries
  if #self.memory_entries > 0 then
    self:restore_memory_references()
  end

  log:info("[Memory] Loaded %d memory entries from %s", #self.memory_entries, self.memory_file_path)
  return true
end

---Restore memory reference messages to the chat
local function restore_memory_references(self)
  -- Add memory reference messages to the beginning of the chat
  local memory_references = {}

  for i, entry in ipairs(self.memory_entries) do
    local memory_reference = {
      role = config.constants.SYSTEM_ROLE,
      content = fmt(
        "[MEMORY] Previous conversation summary (%d messages from cycles %d-%d): %s",
        entry.original_count,
        entry.start_cycle,
        entry.end_cycle,
        entry.summary
      ),
      opts = {
        tag = "memory_summary",
        memory_entry_id = i,
        loaded_from_persistence = true,
      },
    }
    table.insert(memory_references, memory_reference)
  end

  -- Insert at the beginning of the chat messages (after system prompt if any)
  local insert_index = 1
  if
    #self.chat.messages > 0
    and self.chat.messages[1].role == config.constants.SYSTEM_ROLE
    and (not self.chat.messages[1].opts or not self.chat.messages[1].opts.tag)
  then
    insert_index = 2 -- Insert after main system prompt
  end

  for i = #memory_references, 1, -1 do
    table.insert(self.chat.messages, insert_index, memory_references[i])
  end
end

---Restore memory reference messages to the chat
function Memory:restore_memory_references()
  restore_memory_references(self)
end

---Delete memory file from persistent storage
---@return boolean Success status
function Memory:delete_memory()
  if not self.memory_file_path then
    return true
  end

  local memory_file = Path:new(self.memory_file_path)
  if not memory_file:exists() then
    return true
  end

  local success, err = pcall(function()
    memory_file:rm()
  end)

  if not success then
    log:error("[Memory] Failed to delete memory file %s: %s", self.memory_file_path, err)
    return false
  end

  log:debug("[Memory] Deleted memory file %s", self.memory_file_path)
  return true
end

---Clear all memory entries (useful for testing)
function Memory:clear()
  self.memory_entries = {}
  log:debug("[Memory] Cleared all memory entries")
end

---Get memory file information
---@return table|nil Memory file info or nil if no file exists
function Memory:get_memory_file_info()
  if not self.memory_file_path then
    return nil
  end

  local memory_file = Path:new(self.memory_file_path)
  if not memory_file:exists() then
    return nil
  end

  local stat = memory_file:stat()
  return {
    path = self.memory_file_path,
    size = stat.size,
    modified = stat.mtime.sec,
    memory_id = self.memory_id,
  }
end

return Memory
