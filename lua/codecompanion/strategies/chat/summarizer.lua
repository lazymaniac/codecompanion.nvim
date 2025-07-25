--=============================================================================
-- Chat Summarizer - Handles LLM-based summarization of conversation segments
--=============================================================================

local client = require("codecompanion.http")
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")

local fmt = string.format

---@class CodeCompanion.Chat.Summarizer
---@field adapter CodeCompanion.Adapter The adapter to use for summarization
local Summarizer = {}
Summarizer.__index = Summarizer

---Create a new Summarizer instance
---@param adapter CodeCompanion.Adapter The adapter to use for summarization
---@return CodeCompanion.Chat.Summarizer
function Summarizer.new(adapter)
  local self = setmetatable({
    adapter = adapter,
  }, Summarizer)

  log:debug("[Summarizer] Initialized with adapter: %s", adapter.name)
  return self
end

---Build summarization prompt for the LLM
---@param messages table Array of messages to summarize
---@param context? table Additional context information
---@return string The summarization prompt
local function build_summarization_prompt(messages, context)
  local prompt_parts = {
    "You are tasked with creating a concise summary of a conversation segment.",
    "This summary will be used to maintain context in a long conversation that exceeds token limits.",
    "",
    "Instructions:",
    "- Provide a clear, comprehensive summary in 2-3 paragraphs maximum",
    "- Focus on key topics, decisions, and important information",
    "- Preserve technical details and specific requests",
    "- Maintain chronological flow of the conversation",
    "- Include any ongoing tasks or unresolved questions",
    "- Do not include meta-commentary about being an AI",
    "",
    "Conversation to summarize:",
    "",
  }

  -- Add messages to the prompt
  for i, message in ipairs(messages) do
    if message.role == config.constants.USER_ROLE then
      table.insert(prompt_parts, fmt("**User**: %s", message.content or "[No content]"))
    elseif message.role == config.constants.LLM_ROLE then
      table.insert(prompt_parts, fmt("**Assistant**: %s", message.content or "[No content]"))
    elseif message.role == "tool" then
      table.insert(
        prompt_parts,
        fmt("**Tool Output**: %s", message.content and message.content:sub(1, 200) or "[Tool output]")
      )
    end

    -- Add separator between messages for readability
    if i < #messages then
      table.insert(prompt_parts, "")
    end
  end

  table.insert(prompt_parts, "")
  table.insert(prompt_parts, "Please provide a summary that preserves the essential context:")

  return table.concat(prompt_parts, "\n")
end

---Create summarization messages for the LLM request
---@param messages table Array of messages to summarize
---@param context? table Additional context
---@return table Formatted messages for LLM request
local function create_summarization_messages(messages, context)
  local system_prompt =
    [[You are a helpful assistant that creates concise summaries of conversations. Focus on preserving key information, technical details, and important context that would be needed to continue the conversation effectively.]]

  local user_prompt = build_summarization_prompt(messages, context)

  return {
    {
      role = config.constants.SYSTEM_ROLE,
      content = system_prompt,
    },
    {
      role = config.constants.USER_ROLE,
      content = user_prompt,
    },
  }
end

---Summarize messages using the LLM (async)
---@param messages table Array of messages to summarize
---@param context? table Additional context information
---@param callback function Callback function(summary, error_message)
function Summarizer:summarize(messages, context, callback)
  if not messages or #messages == 0 then
    return callback(nil, "No messages to summarize")
  end

  log:debug("[Summarizer] Starting summarization of %d messages", #messages)

  -- Prepare the request
  local summarization_messages = create_summarization_messages(messages, context)

  -- Build payload for the adapter
  local payload = {
    messages = self.adapter:map_roles(summarization_messages),
  }

  -- Add adapter-specific parameters (use conservative settings for summarization)
  local settings = {}
  if self.adapter.schema.temperature then
    settings.temperature = 0.3 -- Low temperature for consistent summaries
  end
  if self.adapter.schema.max_tokens then
    settings.max_tokens = 500 -- Limit summary length
  end

  local mapped_settings = self.adapter:map_schema_to_params(settings)

  -- Merge payload with settings
  for key, value in pairs(mapped_settings) do
    payload[key] = value
  end

  log:trace("[Summarizer] Payload: %s", vim.inspect(payload))

  -- Create the HTTP client
  local http_client = client.new({ adapter = self.adapter })

  -- Make async request
  http_client:post({
    url = self.adapter.url,
    headers = self.adapter.headers,
    body = vim.tbl_deep_extend("force", self.adapter.body, payload),
    raw = self.adapter.raw,
  }, function(err, response)
    if err then
      local error_msg = fmt("Failed to make summarization request: %s", tostring(err))
      log:error("[Summarizer] %s", error_msg)
      return callback(nil, error_msg)
    end

    if not response or response.status ~= 200 then
      local error_msg = fmt("Summarization request failed with status: %s", response and response.status or "unknown")
      log:error("[Summarizer] %s", error_msg)
      return callback(nil, error_msg)
    end

    -- Parse the response
    local success, parsed_response = pcall(self.adapter.handlers.chat_output, self.adapter, response.body, {})

    if not success or not parsed_response or not parsed_response.content then
      local error_msg = "Failed to parse summarization response"
      log:error("[Summarizer] %s", error_msg)
      return callback(nil, error_msg)
    end

    local summary = parsed_response.content
    log:debug("[Summarizer] Generated summary (%d chars): %s...", #summary, summary:sub(1, 100))

    callback(summary, nil)
  end)
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

  if #recent_content > 0 then
    table.insert(summary_parts, "Recent context: " .. table.concat(recent_content, " | "))
  end

  return table.concat(summary_parts, ". ")
end

---Synchronous summarization with fallback (for when async isn't suitable)
---@param messages table Array of messages to summarize
---@param context? table Additional context information
---@return string Summary text (never nil)
function Summarizer:summarize_sync_with_fallback(messages, context)
  log:warn("[Summarizer] Using synchronous fallback summarization (LLM async not available)")
  return create_fallback_summary(messages, context)
end

return Summarizer
