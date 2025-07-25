local h = require("tests.helpers")
T["agent tool reasoning mode"] = function()
  local agent_tool = require("codecompanion.strategies.chat.agents.tools.agent")
  
  local mock_chat = {
    tools = {
      in_use = {
        grep_search = true,
        file_search = true
      }
    },
    tools_config = {}
  }
  mock_chat.add_tool_output = function() end -- Mock function
  
  local tool_instance = {
    name = "agent",
    args = {
      mode = "reason",
      task = "Test task for reasoning",
      confidence_threshold = 0.5 -- Lower threshold for testing
    },
    chat = mock_chat
  }
  
  local cmd_func = agent_tool.cmds[1]
  local result = cmd_func(tool_instance, tool_instance.args)
  
  MiniTest.expect.equality(result.status, "success")
  MiniTest.expect.no_equality(result.data, nil)
  MiniTest.expect.equality(result.data.phase, "reasoning_complete")
  MiniTest.expect.no_equality(result.data.plan, nil)
  MiniTest.expect.no_equality(result.data.plan.id, nil)
end

T["agent tool schema"] = function()
local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[_G.config = require("codecompanion.config")]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})
  local agent_tool = require("codecompanion.strategies.chat.agents.tools.agent")

T["agent tool error handling"] = function()
  local agent_tool = require("codecompanion.strategies.chat.agents.tools.agent")
  
  local mock_chat = {
    tools = { in_use = {} },
    tools_config = {}
  }
  mock_chat.add_tool_output = function() end
  
  -- Test missing task parameter
  local tool_instance = {
    name = "agent",
    args = { mode = "reason" }, -- Missing task
    chat = mock_chat
  }
  
  local cmd_func = agent_tool.cmds[1]
  local result = cmd_func(tool_instance, tool_instance.args)
  
  MiniTest.expect.equality(result.status, "error")
  MiniTest.expect.equality(result.data:match("Task parameter is required") ~= nil, true)
end

T["agent tool output handlers"] = function()
  local agent_tool = require("codecompanion.strategies.chat.agents.tools.agent")
  
  -- Test that output handlers exist
  MiniTest.expect.no_equality(agent_tool.output.success, nil)
  MiniTest.expect.equality(type(agent_tool.output.success), "function")
  MiniTest.expect.no_equality(agent_tool.output.error, nil)
  MiniTest.expect.equality(type(agent_tool.output.error), "function")
  MiniTest.expect.no_equality(agent_tool.output.rejected, nil)
  MiniTest.expect.equality(type(agent_tool.output.rejected), "function")
  MiniTest.expect.no_equality(agent_tool.output.prompt, nil)
  MiniTest.expect.equality(type(agent_tool.output.prompt), "function")
end

  
  -- Test that schema exists and has correct structure
  MiniTest.expect.no_equality(agent_tool.schema, nil)
  MiniTest.expect.equality(agent_tool.schema.type, "function")
  MiniTest.expect.equality(agent_tool.schema["function"].name, "agent")
  MiniTest.expect.no_equality(agent_tool.schema["function"].description, nil)
  MiniTest.expect.no_equality(agent_tool.schema["function"].parameters, nil)
  
  -- Test required parameters
  local required = agent_tool.schema["function"].parameters.required
  MiniTest.expect.equality(vim.tbl_contains(required, "mode"), true)
  
  -- Test mode enum values
  local mode_enum = agent_tool.schema["function"].parameters.properties.mode.enum
  MiniTest.expect.equality(vim.tbl_contains(mode_enum, "reason"), true)
  MiniTest.expect.equality(vim.tbl_contains(mode_enum, "execute"), true)
  MiniTest.expect.equality(vim.tbl_contains(mode_enum, "reflect"), true)
end












return T