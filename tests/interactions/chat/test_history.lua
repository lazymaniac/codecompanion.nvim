local h = require("tests.helpers")

local expect = MiniTest.expect
local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        codecompanion = require("codecompanion")
        h = require('tests.helpers')
        _G.chat, _G.tools = h.setup_chat_buffer()

        -- Set up a temporary history directory for testing
        _G.test_history_dir = vim.fn.tempname() .. "/codecompanion_test_history"
        require("codecompanion.config").interactions.chat.history = {
          enabled = true,
          auto_save = false,
          dir = _G.test_history_dir,
          max_items = 5,
        }
      ]])
    end,
    post_case = function()
      child.lua([[
        h.teardown_chat_buffer()
        -- Clean up test history directory
        if _G.test_history_dir then
          vim.fn.delete(_G.test_history_dir, "rf")
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["History"] = new_set()

T["History"]["can save and load a chat"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    -- Add some messages to the chat
    chat:add_message({ role = "user", content = "Hello, how are you?" })
    chat:add_message({ role = "llm", content = "I am doing well, thank you!" })

    -- Save the chat
    local id = history.save(chat)
    if not id then
      return { error = "Failed to save chat" }
    end

    -- Load the chat data
    local loaded = history.load(id)
    if not loaded then
      return { error = "Failed to load chat" }
    end

    return {
      id = id,
      message_count = #loaded.messages,
      first_user_msg = loaded.messages[2] and loaded.messages[2].content or nil,
    }
  ]])

  h.eq(nil, result.error)
  h.eq(true, result.id ~= nil)
  h.eq(3, result.message_count) -- system + user + llm
  h.eq("Hello, how are you?", result.first_user_msg)
end

T["History"]["can list saved chats"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    -- Save multiple chats
    chat:add_message({ role = "user", content = "First chat message" })
    local id1 = history.save(chat)

    -- Simulate a new chat by changing the history ID
    chat._history_id = nil
    chat:add_message({ role = "user", content = "Second chat message" })
    local id2 = history.save(chat)

    -- List all chats
    local list = history.list()

    return {
      count = #list,
      has_id1 = vim.tbl_contains(vim.tbl_map(function(c) return c.id end, list), id1),
      has_id2 = vim.tbl_contains(vim.tbl_map(function(c) return c.id end, list), id2),
    }
  ]])

  h.eq(2, result.count)
  h.eq(true, result.has_id1)
  h.eq(true, result.has_id2)
end

T["History"]["can get last chat"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    -- Save a chat
    chat:add_message({ role = "user", content = "This is the last chat" })
    local id = history.save(chat)

    -- Get last chat
    local last = history.get_last()

    return {
      has_last = last ~= nil,
      id_matches = last and last.id == id,
    }
  ]])

  h.eq(true, result.has_last)
  h.eq(true, result.id_matches)
end

T["History"]["can delete a chat"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    -- Save a chat
    chat:add_message({ role = "user", content = "Chat to delete" })
    local id = history.save(chat)

    -- Verify it exists
    local before_count = #history.list()

    -- Delete it
    local deleted = history.delete(id)

    -- Verify it's gone
    local after_count = #history.list()
    local loaded = history.load(id)

    return {
      deleted = deleted,
      before_count = before_count,
      after_count = after_count,
      still_exists = loaded ~= nil,
    }
  ]])

  h.eq(true, result.deleted)
  h.eq(1, result.before_count)
  h.eq(0, result.after_count)
  h.eq(false, result.still_exists)
end

T["History"]["can clear all history"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    -- Save multiple chats
    chat:add_message({ role = "user", content = "Chat 1" })
    history.save(chat)

    chat._history_id = nil
    chat:add_message({ role = "user", content = "Chat 2" })
    history.save(chat)

    local before_count = #history.list()

    -- Clear all
    local cleared = history.clear()

    local after_count = #history.list()

    return {
      cleared = cleared,
      before_count = before_count,
      after_count = after_count,
    }
  ]])

  h.eq(true, result.cleared)
  h.eq(2, result.before_count)
  h.eq(0, result.after_count)
end

T["History"]["respects max_items limit"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    -- Save more chats than max_items (5)
    for i = 1, 7 do
      chat._history_id = nil
      chat:add_message({ role = "user", content = "Chat " .. i })
      history.save(chat)
    end

    local list = history.list()

    return {
      count = #list,
    }
  ]])

  h.eq(5, result.count) -- Should be limited to max_items
end

T["History"]["extracts title from first user message"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local chat = _G.chat

    chat:add_message({ role = "user", content = "How do I write a Lua function?" })
    local id = history.save(chat)

    local list = history.list()
    local saved = vim.iter(list):find(function(c) return c.id == id end)

    return {
      title = saved and saved.title or nil,
    }
  ]])

  h.eq("How do I write a Lua function?", result.title)
end

T["History"]["does not save empty chats"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")

    -- Create a new chat with no messages
    local Chat = require("codecompanion.interactions.chat")
    local empty_chat = {
      messages = {},
      adapter = { name = "test" },
    }

    local id = history.save(empty_chat)

    return {
      saved = id ~= nil,
    }
  ]])

  h.eq(false, result.saved)
end

T["History"]["disabled when config.enabled is false"] = function()
  local result = child.lua([[
    local history = require("codecompanion.interactions.chat.history")
    local config = require("codecompanion.config")

    -- Disable history
    config.interactions.chat.history.enabled = false

    local chat = _G.chat
    chat:add_message({ role = "user", content = "This should not be saved" })
    local id = history.save(chat)

    -- Re-enable for cleanup
    config.interactions.chat.history.enabled = true

    return {
      saved = id ~= nil,
    }
  ]])

  h.eq(false, result.saved)
end

return T
