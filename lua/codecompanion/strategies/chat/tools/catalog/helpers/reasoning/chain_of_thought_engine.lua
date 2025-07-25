---@class CodeCompanion.ChainOfThoughtEngine

local ChainOfThought = require("codecompanion.strategies.chat.tools.catalog.helpers.reasoning.chain_of_thoughts").ChainOfThought
local log = require("codecompanion.utils.log")
local fmt = string.format

local ChainOfThoughtEngine = {}

local Actions = {}

function Actions.initialize(args, agent_state)
  log:debug("[Chain of Thought Engine] Initializing session: %s", args.problem or "nil")

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = ChainOfThought.new(args.problem)
  agent_state.current_instance.agent_type = "Chain of Thought Agent"

  agent_state.current_instance.get_element = function(self, id)
    for _, step in ipairs(self.steps) do
      if step.id == id then
        return step
      end
    end
    return nil
  end

  agent_state.current_instance.update_element_score = function(self, id, boost)
    -- Chain of thought doesn't use scoring, but we maintain interface
    return true
  end

  return {
    status = "success",
    data = fmt(
      "Chain of Thought initialized.\nProblem: %s\nSession ID: %s\n\nActions available:\n- add_step: Add reasoning step to chain\n- validate_step: Check step quality\n- view_chain: See full reasoning chain\n- complete_chain: Finalize reasoning\n- reflect: Analyze reasoning process",
      args.problem,
      agent_state.session_id
    ),
  }
end

function Actions.add_step(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active chain. Initialize first." }
  end

  local success, message = agent_state.current_instance:add_step(args.step_type, args.content, args.reasoning or "", args.step_id)
  if not success then
    return { status = "error", data = message }
  end

  return {
    status = "success",
    data = fmt(
      "Added reasoning step '%s'.\nContent: %s\nType: %s\nStep %d of chain",
      args.step_id,
      args.content,
      args.step_type,
      #agent_state.current_instance.steps
    ),
  }
end

function Actions.validate_step(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active chain. Initialize first." }
  end

  local target_step = agent_state.current_instance:get_element(args.step_id)
  if not target_step then
    return { status = "error", data = fmt("Step '%s' not found", args.step_id) }
  end

  return {
    status = "success",
    data = fmt("Step '%s' validated successfully.", args.step_id),
  }
end

function Actions.view_chain(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active chain. Initialize first." }
  end

  local chain_view = "=== CHAIN OF THOUGHT ===\n"
  local problem_str = type(agent_state.current_instance.problem) == "table"
      and vim.inspect(agent_state.current_instance.problem)
    or tostring(agent_state.current_instance.problem)
  chain_view = chain_view .. "Problem: " .. problem_str .. "\n\n"

  for i, step in ipairs(agent_state.current_instance.steps) do
    chain_view = chain_view .. string.format("Step %d: %s (%s)\n", i, step.id, step.type)
    chain_view = chain_view .. "Content: " .. step.content .. "\n"
    chain_view = chain_view .. "Reasoning: " .. step.reasoning .. "\n\n"
  end

  chain_view = chain_view .. string.format("Total Steps: %d\n", #agent_state.current_instance.steps)

  return {
    status = "success",
    data = chain_view,
  }
end

function Actions.reflect(args, agent_state)
  local chain_reflection = agent_state.current_instance and agent_state.current_instance:reflect()
    or { insights = {}, step_distribution = {} }

  local reflection = {
    timestamp = os.time(),
    content = args.reflection,
    chain_length = agent_state.current_instance and #agent_state.current_instance.steps or 0,
    insights = args.insights or chain_reflection.insights,
    improvements = args.improvements or {},
  }

  local insights_text = ""
  if #reflection.insights > 0 then
    insights_text = "\n\nInsights:\n"
      .. table.concat(
        vim.tbl_map(function(insight)
          return "- " .. insight
        end, reflection.insights),
        "\n"
      )
  end

  return {
    status = "success",
    data = fmt("Reflection recorded: %s%s", reflection.content, insights_text),
  }
end

-- ============================================================================
-- ENGINE CONFIGURATION
-- ============================================================================
function ChainOfThoughtEngine.get_config()
  return {
    agent_type = "Chain of Thought Agent",
    tool_name = "chain_of_thought_agent",
    description = "Chain of Thought reasoning agent that follows sequential logical steps to solve complex problems systematically.",
    actions = Actions,
    validation_rules = {
      initialize = { "problem" },
      add_step = { "step_id", "content", "step_type" },
      validate_step = { "step_id" },
      view_chain = {},
      reflect = { "reflection" },
    },
    parameters = {
      type = "object",
      properties = {
        action = {
          type = "string",
          description = "The reasoning action to perform: 'initialize', 'add_step', 'validate_step', 'view_chain', 'reflect'",
        },
        problem = {
          type = "string",
          description = "The problem to solve using chain of thought reasoning (required for 'initialize' action)",
        },
        step_id = {
          type = "string",
          description = "Unique identifier for the reasoning step (required for 'add_step', 'validate_step')",
        },
        content = {
          type = "string",
          description = "The reasoning step content or thought (required for 'add_step')",
        },
        step_type = {
          type = "string",
          description = "Type of reasoning step: 'analysis', 'reasoning', 'task', 'validation' (required for 'add_step')",
        },
        reasoning = {
          type = "string",
          description = "Detailed explanation of the reasoning behind this step (for 'add_step')",
        },
        reflection = {
          type = "string",
          description = "Reflection on the reasoning process and outcomes (required for 'reflect')",
        },
      },
      required = { "action" },
      additionalProperties = false,
    },
    system_prompt_config = function()
      local UnifiedSystemPrompt = require("codecompanion.strategies.chat.tools.catalog.helpers.unified_system_prompt")
      return UnifiedSystemPrompt.chain_of_thought_config()
    end,
  }
end

return ChainOfThoughtEngine
