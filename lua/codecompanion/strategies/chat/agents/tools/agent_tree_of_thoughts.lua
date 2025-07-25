--[[
Requirements:

I want the agent to use real tree of thought pattern to solve the problem through deliberate reasoning. 
I want it to explore possible solutions taking multiple paths, follow each one of them and find the best one. 
As a result of this reasoning process agent should create a list of well defined tasks.

Agent should have access to all other tools already implemented in my plugin. It should be able to call any 
of them to conduct three of thoughts process to find best solution and use them to implement each task.

Agent should be a general purpose one. No particular focus on specific domain like programming.

The workflow should be:
1. User shares a prompt with problem to solve with agent tool.
2. Agent starts to analyze the problem with tree of thoughts pattern. Suggest possible solutions from general 
   thoughts and follows them rejects them to find best on.
3. After finding the best solution agent creates a plan in the form of well defined, ordered task list.
4. Agent starts to implement tasks in order.
5. Agent reflects to refine the plan if necessary after each task. Adds new tasks, deletes tasks that are not 
   required anymore, marks the tasks as done or in progress. Plan refinement should also follow tree of thoughts pattern.

Agent should deeply explore how to solve the given problem with confidence before it starts to execute the plan.

--]]
local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local fmt = string.format

---@class AgentPlan
---@field id string Unique plan identifier
---@field task string The task to solve
---@field approach string Selected approach name
---@field confidence number Confidence score (0-1)
---@field status string Plan status
---@field steps table[] Execution steps
---@field reasoning string Reasoning explanation
---@field created_at string Creation timestamp
---@field context table Additional context data
---@field thought_processes table[] Original LLM-generated thought processes
---@field selected_thought_id string ID of selected thought process

---@class AgentReasoningPath
---@field id string Path identifier
---@field approach table Approach details
---@field confidence number Confidence score
---@field steps table[] Steps to execute
---@field reasoning string Reasoning explanation
---@field reasoning_chain table[] Detailed reasoning branches
---@field evaluation table Evaluation metrics
---@field risks table[] Identified risks
---@field mitigations table[] Risk mitigations

---State management for the agent's reasoning and planning
---@class AgentState
---@field plans table<string, table> Active execution plans
---@field current_plan_id string? Currently active plan
---@field reasoning_history table[] History of reasoning decisions
---@field tool_execution_log table[] Log of tool executions
---@field cleanup_time number Timestamp for cleanup
local AgentState = {}
AgentState.__index = AgentState

---Create new agent state instance
---@return AgentState
function AgentState.new()
  return setmetatable({
    plans = {},
    current_plan_id = nil,
    reasoning_history = {},
    tool_execution_log = {},
    cleanup_time = os.time() + 3600, -- Cleanup after 1 hour
  }, AgentState)
end

---Get or create state for a chat instance
---@param chat table Chat instance
---@return AgentState
local function get_agent_state(chat)
  if not chat._agent_state then
    chat._agent_state = AgentState.new()
  end

  -- Cleanup old state if needed
  local state = chat._agent_state
  if os.time() > state.cleanup_time then
    state.plans = {}
    state.reasoning_history = {}
    state.tool_execution_log = {}
    state.cleanup_time = os.time() + 3600
  end

  return state
end

---Generate tree of thoughts prompt for LLM reasoning
---@param task string The task to analyze
---@param available_tools table[] Available tools
---@param num_thoughts number Number of thought processes to generate
---@return string Structured prompt for tree of thoughts
local function generate_tree_of_thoughts_prompt(task, available_tools, num_thoughts)
  num_thoughts = num_thoughts or 4
  
  local tools_list = table.concat(available_tools, ", ")
  
  return string.format([[
TREE OF THOUGHTS REASONING TASK:

OBJECTIVE: %s
AVAILABLE TOOLS: %s

You must generate %d distinct thought processes to solve this objective. Each thought process should explore a completely different approach or angle.

For each thought process, provide:

1. APPROACH: Unique strategy with name and description
2. REASONING CHAIN: Develop 3-5 reasoning branches exploring different aspects:
   - What are the key challenges?
   - What information is needed?
   - What are alternative approaches?
   - What could go wrong?
   - How to validate success?
3. STEP BREAKDOWN: Define specific actionable steps using only available tools
4. EVALUATION: Score feasibility (0-1), completeness (0-1), tool_availability (0-1), overall_score (0-1)
5. RISKS & MITIGATIONS: Identify 2-3 potential issues and how to address them

Think deeply about:
- Different problem-solving philosophies
- Various entry points to the problem
- Short-term vs long-term approaches
- Conservative vs aggressive strategies
- Sequential vs parallel execution
- Research-heavy vs action-heavy approaches

FORMAT YOUR RESPONSE AS VALID JSON:
```json
{
  "thought_processes": [
    {
      "id": "unique_approach_id",
      "name": "Approach Name",
      "description": "Detailed description of this approach philosophy",
      "reasoning_chain": [
        {
          "branch": "challenge_analysis",
          "thoughts": ["What makes this problem difficult?", "What constraints exist?", "What resources are available?"],
          "conclusion": "Key challenge insight"
        },
        {
          "branch": "solution_exploration", 
          "thoughts": ["What are different ways to solve this?", "What has worked before?", "What's innovative?"],
          "conclusion": "Solution approach decision"
        },
        {
          "branch": "implementation_strategy",
          "thoughts": ["How to break this down?", "What order makes sense?", "What dependencies exist?"],
          "conclusion": "Implementation approach"
        }
      ],
      "steps": [
        {
          "action": "specific_action_name",
          "tools": ["tool1", "tool2"],
          "reasoning": "why this step is necessary",
          "expected_outcome": "what this achieves",
          "dependencies": ["previous_step_id"],
          "priority": "high|medium|low"
        }
      ],
      "evaluation": {
        "feasibility": 0.8,
        "completeness": 0.9,
        "tool_availability": 0.7,
        "overall_score": 0.8,
        "reasoning": "why this score"
      },
      "risks": ["risk1", "risk2", "risk3"],
      "mitigations": ["how to handle risk1", "how to handle risk2", "how to handle risk3"]
    }
  ],
  "meta_analysis": {
    "approach_diversity": "how different are the approaches",
    "coverage_assessment": "what aspects of the problem are covered",
    "recommendation": {
      "best_approach_id": "selected_id",
      "reasoning": "comprehensive explanation of why this is best",
      "confidence": 0.85,
      "alternative_consideration": "what makes other approaches less suitable"
    }
  }
}
```

CRITICAL: Be creative and explore genuinely different approaches. Avoid similar strategies. Think like different experts would approach this problem.]], 
    task, tools_list, num_thoughts)
end

---Execute tree of thoughts reasoning with LLM
---@param task string The task to reason about
---@param available_tools table[] Available tools
---@param chat table Chat context for LLM calls
---@param num_thoughts number Number of thought processes
---@return table[] Array of reasoning paths or error
local function execute_tree_of_thoughts_reasoning(task, available_tools, chat, num_thoughts)
  local prompt = generate_tree_of_thoughts_prompt(task, available_tools, num_thoughts)
  
  -- This would normally call the LLM, but for now we'll return a placeholder
  -- In a real implementation, you'd use chat:add_message() or similar
  log:debug("[Agent Tool] Generated tree of thoughts prompt for task: %s", task)
  
  -- For now, return a structured example of what the LLM should generate
  local example_response = {
    thought_processes = {
      {
        id = "systematic_analysis",
        name = "Systematic Analysis Approach", 
        description = "Break down the problem systematically and address each component methodically",
        reasoning_chain = {
          {
            branch = "challenge_analysis",
            thoughts = {"What are the core requirements?", "What are the constraints?", "What complexity exists?"},
            conclusion = "Problem requires structured decomposition"
          },
          {
            branch = "solution_exploration",
            thoughts = {"What proven methods exist?", "What tools are available?", "What's the minimal viable approach?"},
            conclusion = "Use available tools in logical sequence"
          }
        },
        steps = {
          {
            action = "analyze_requirements",
            tools = {"grep_search", "file_search"},
            reasoning = "Need to understand current state",
            expected_outcome = "Clear understanding of requirements",
            priority = "high"
          },
          {
            action = "implement_solution",
            tools = {"create_file", "insert_edit_into_file"},
            reasoning = "Apply the solution systematically",
            expected_outcome = "Working implementation",
            priority = "high"
          }
        },
        evaluation = {
          feasibility = 0.9,
          completeness = 0.8,
          tool_availability = 0.9,
          overall_score = 0.85,
          reasoning = "Systematic approach with good tool coverage"
        },
        risks = {"May be slow", "Could miss creative solutions"},
        mitigations = {"Set time limits", "Include brainstorming phase"}
      }
    },
    meta_analysis = {
      approach_diversity = "Single example provided",
      coverage_assessment = "Basic systematic coverage",
      recommendation = {
        best_approach_id = "systematic_analysis",
        reasoning = "Most reliable approach given available tools",
        confidence = 0.85,
        alternative_consideration = "No alternatives in this example"
      }
    }
  }
  
  return parse_tree_of_thoughts_response(vim.json.encode(example_response))
end

---Parse LLM response into reasoning paths
---@param llm_response string JSON response from LLM
---@return table[] Array of reasoning paths and meta information
local function parse_tree_of_thoughts_response(llm_response)
  local success, parsed = pcall(vim.json.decode, llm_response)
  if not success or not parsed.thought_processes then
    log:warn("[Agent Tool] Failed to parse tree of thoughts response: %s", llm_response)
    return {paths = {}, meta = {}}
  end
  
  local paths = {}
  for _, thought in ipairs(parsed.thought_processes) do
    local path = {
      id = thought.id or "unknown",
      approach = {
        name = thought.name or "Unknown",
        description = thought.description or ""
      },
      confidence = thought.evaluation and thought.evaluation.overall_score or 0.5,
      steps = thought.steps or {},
      reasoning = generate_reasoning_summary(thought),
      reasoning_chain = thought.reasoning_chain or {},
      evaluation = thought.evaluation or {},
      risks = thought.risks or {},
      mitigations = thought.mitigations or {}
    }
    table.insert(paths, path)
  end
  
  -- Sort by confidence
  table.sort(paths, function(a, b) return a.confidence > b.confidence end)
  
  return {
    paths = paths,
    meta = parsed.meta_analysis or {},
    prompt_used = generate_tree_of_thoughts_prompt("task", {}, 4) -- Include for reference
  }
end

---Generate reasoning summary from thought process
---@param thought table Thought process data
---@return string Reasoning summary
local function generate_reasoning_summary(thought)
  local parts = {}
  
  if thought.description then
    table.insert(parts, thought.description)
  end
  
  if thought.reasoning_chain then
    local chain_summary = {}
    for _, branch in ipairs(thought.reasoning_chain) do
      if branch.conclusion then
        table.insert(chain_summary, branch.conclusion)
      end
    end
    if #chain_summary > 0 then
      table.insert(parts, "Reasoning: " .. table.concat(chain_summary, "; "))
    end
  end
  
  if thought.evaluation then
    table.insert(parts, string.format("Score: %.2f/1.0", thought.evaluation.overall_score or 0))
  end
  
  return table.concat(parts, ". ")
end

---Select the best reasoning path from tree of thoughts results
---@param thought_result table Result from tree of thoughts with paths and meta
---@return AgentReasoningPath? Best path
local function select_best_thought_path(thought_result)
  if not thought_result.paths or #thought_result.paths == 0 then
    return nil
  end
  
  -- If meta analysis provides recommendation, use that
  if thought_result.meta and thought_result.meta.recommendation then
    local recommended_id = thought_result.meta.recommendation.best_approach_id
    for _, path in ipairs(thought_result.paths) do
      if path.id == recommended_id then
        return path
      end
    end
  end
  
  -- Fallback to highest confidence
  return thought_result.paths[1] -- Already sorted by confidence
end

---Create execution plan from selected thought path
---@param path AgentReasoningPath Selected reasoning path
---@param task string Original task
---@param thought_result table Full tree of thoughts result
---@return AgentPlan Execution plan
local function create_execution_plan(path, task, thought_result)
  if not path or not task then
    error("Invalid path or task provided to create_execution_plan")
  end

  local plan_id = "plan_" .. os.time() .. "_" .. math.random(1000, 9999)

  ---@type AgentPlan
  local plan = {
    id = plan_id,
    task = task,
    approach = path.approach and path.approach.name or "unknown",
    confidence = path.confidence,
    status = "created",
    steps = path.steps,
    reasoning = path.reasoning,
    created_at = os.date("%Y-%m-%d %H:%M:%S"),
    context = {
      tool_availability_checked = true,
      original_confidence = path.confidence,
      tree_of_thoughts_used = true,
      thought_processes_considered = #(thought_result.paths or {}),
    },
    thought_processes = thought_result.paths or {},
    selected_thought_id = path.id,
  }

  return plan
end

---Get available tools from chat context
---@param chat table Chat context
---@return table[] Available tools
local function get_available_tools(chat)
  if not chat then
    log:warn("[Agent Tool] No chat context provided, using fallback tools")
    return {
      "grep_search",
      "file_search", 
      "read_file",
      "create_file",
      "insert_edit_into_file",
      "cmd_runner",
    }
  end

  local available_tools = {}

  if chat and chat.tools and chat.tools.in_use then
    for tool_name, _ in pairs(chat.tools.in_use) do
      if tool_name ~= "agent" then -- Don't include self
        table.insert(available_tools, tool_name)
      end
    end
  else
    -- Fallback to common tools
    available_tools = {
      "grep_search",
      "file_search",
      "read_file", 
      "create_file",
      "insert_edit_into_file",
      "cmd_runner",
      "web_search",
      "get_changed_files",
    }
  end

  return available_tools
end

---Validate task input
---@param task string
---@return boolean valid
---@return string? error_message
local function validate_task(task)
  if not task or type(task) ~= "string" then
    return false, "Task must be a non-empty string"
  end

  if task:len() == 0 or task:match("^%s*$") then
    return false, "Task cannot be empty or whitespace only"
  end

  if task:len() > 10000 then
    return false, "Task description too long (max 10000 characters)"
  end

  return true
end

---Validate confidence threshold
---@param threshold number
---@return boolean valid
---@return string? error_message
local function validate_confidence_threshold(threshold)
  if type(threshold) ~= "number" then
    return false, "Confidence threshold must be a number"
  end

  if threshold < 0 or threshold > 1 then
    return false, "Confidence threshold must be between 0 and 1"
  end

  return true
end

---Process reasoning mode with tree of thoughts
---@param args table Arguments from tool call
---@param chat table Chat context
---@return table Result
local function process_reasoning_mode(args, chat)
  local task = args.task
  local confidence_threshold = args.confidence_threshold or 0.8
  local num_thoughts = args.num_thoughts or 4

  -- Validate inputs
  local valid, error_msg = validate_task(task)
  if not valid then
    return {
      status = "error",
      data = error_msg,
    }
  end

  valid, error_msg = validate_confidence_threshold(confidence_threshold)
  if not valid then
    return {
      status = "error",
      data = error_msg,
    }
  end

  local state = get_agent_state(chat)
  local available_tools = get_available_tools(chat)

  log:debug("[Agent Tool] Starting tree of thoughts reasoning for task: %s", task)
  log:debug("[Agent Tool] Available tools: %s", table.concat(available_tools, ", "))

  -- Execute tree of thoughts reasoning
  local thought_result = execute_tree_of_thoughts_reasoning(task, available_tools, chat, num_thoughts)
  local best_path = select_best_thought_path(thought_result)

  if not best_path or best_path.confidence < confidence_threshold then
    log:debug(
      "[Agent Tool] No suitable path found. Best confidence: %s, Threshold: %s",
      best_path and best_path.confidence or "none",
      confidence_threshold
    )
    return {
      status = "error",
      data = {
        error_type = "insufficient_confidence",
        message = "No reasoning path meets confidence threshold",
        best_confidence = best_path and best_path.confidence or 0,
        threshold = confidence_threshold,
        available_tools = available_tools,
        paths_considered = #(thought_result.paths or {}),
        tree_of_thoughts_prompt = thought_result.prompt_used,
      },
    }
  end

  -- Create and store execution plan
  local execution_plan = create_execution_plan(best_path, task, thought_result)
  state.plans[execution_plan.id] = execution_plan
  state.current_plan_id = execution_plan.id

  -- Record reasoning decision
  table.insert(state.reasoning_history, {
    task = task,
    paths_considered = #(thought_result.paths or {}),
    selected_path_id = best_path.id,
    confidence = best_path.confidence,
    reasoning = best_path.reasoning,
    timestamp = os.time(),
    plan_id = execution_plan.id,
    tree_of_thoughts_used = true,
    meta_analysis = thought_result.meta,
  })

  log:debug("[Agent Tool] Created plan: %s with confidence: %.2f", execution_plan.id, execution_plan.confidence)

  return {
    status = "success",
    data = {
      phase = "reasoning_complete",
      plan = execution_plan,
      paths_considered = #(thought_result.paths or {}),
      available_tools = available_tools,
      tree_of_thoughts_meta = thought_result.meta,
    },
  }
end

-- Simple placeholder implementations for execute and reflect modes
-- These would need to be implemented similarly with proper tree of thoughts

local function process_execute_mode(args, chat)
  return {
    status = "success", 
    data = {
      phase = "execution_placeholder",
      message = "Execute mode needs to be implemented with tree of thoughts"
    }
  }
end

local function process_reflect_mode(args, chat)
  return {
    status = "success",
    data = {
      phase = "reflection_placeholder", 
      message = "Reflect mode needs to be implemented with tree of thoughts"
    }
  }
end

---@class CodeCompanion.Tool.Agent: CodeCompanion.Agent.Tool
return {
  name = "agent",
  cmds = {
    ---Execute the agent's reasoning, task execution, or reflection based on mode
    ---@param self CodeCompanion.Tool.Agent
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string|table }
    function(self, args, input)
      -- Early validation
      if not args or type(args) ~= "table" then
        return {
          status = "error",
          data = "Invalid arguments provided to agent tool",
        }
      end

      local mode = args.mode or "reason"
      local chat = self.chat

      log:debug("[Agent Tool] Mode: %s", mode)

      if mode == "reason" then
        return process_reasoning_mode(args, chat)
      elseif mode == "execute" then
        return process_execute_mode(args, chat)
      elseif mode == "reflect" then
        return process_reflect_mode(args, chat)
      else
        return {
          status = "error",
          data = fmt("Unknown mode: %s. Valid modes are: reason, execute, reflect", mode),
        }
      end
    end,
  },
  schema = {
    ["function"] = {
      name = "agent",
      description = "AI agent that uses tree of thoughts reasoning to analyze problems and create execution plans. The agent generates multiple thought processes, evaluates them, and selects the best approach.",
      parameters = {
        type = "object",
        properties = {
          mode = {
            type = "string",
            enum = { "reason", "execute", "reflect" },
            description = "Agent operation mode: 'reason' for tree of thoughts analysis, 'execute' for task execution, 'reflect' for plan refinement",
          },
          task = {
            type = "string",
            description = "The main task or problem to solve (required for 'reason' mode)",
          },
          confidence_threshold = {
            type = "number",
            description = "Minimum confidence score to proceed (default: 0.8)",
          },
          num_thoughts = {
            type = "number", 
            description = "Number of thought processes to generate (default: 4)",
          },
          plan_id = {
            type = "string",
            description = "Plan identifier (required for 'execute' and 'reflect' modes)",
          },
        },
        required = { "mode" },
      },
    },
    type = "function",
  },
  handlers = {
    on_exit = function(agent)
      log:trace("[Agent Tool] on_exit handler executed")
    end,
  },
  output = {
    prompt = function(self, agent)
      local args = self.args
      if not args then
        return "Execute AI agent operation?"
      end

      local mode = args.mode or "reason"
      local task = args.task or "unknown task"

      if mode == "reason" then
        return fmt("Start AI agent tree of thoughts reasoning for task: %s?", task)
      elseif mode == "execute" then
        return fmt("Execute plan %s?", args.plan_id or "unknown")
      elseif mode == "reflect" then
        return fmt("Reflect on plan %s?", args.plan_id or "unknown")
      end

      return "Execute AI agent operation?"
    end,

    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      if not chat then
        log:error("[Agent Tool] No chat context available")
        return
      end

      local data = stdout[1]
      local output = ""

      if type(data) == "table" then
        if data.phase == "reasoning_complete" then
          local plan = data.plan
          if plan then
            output = fmt(
              [[<agentTool>🧠 **AI Agent - Tree of Thoughts Complete**

**Task:** %s
**Selected Approach:** %s (Confidence: %.1f%%)
**Available Tools:** %s
**Thought Processes Considered:** %d

**📋 Execution Plan Created:**
- **Plan ID:** `%s`
- **Approach:** %s
- **Reasoning:** %s
- **Status:** %s

**Tree of Thoughts Analysis:**
- Multiple reasoning paths explored
- Best approach selected based on evaluation
- Plan ready for execution

**Next Steps:** Use execute mode with plan_id: `%s` to begin implementation.</agentTool>]],
              plan.task or "Unknown",
              plan.approach or "Unknown",
              (plan.confidence or 0) * 100,
              table.concat(data.available_tools or {}, ", "),
              data.paths_considered or 0,
              plan.id,
              plan.approach or "Unknown",
              plan.reasoning or "No reasoning provided",
              plan.status or "unknown",
              plan.id
            )
          end
        else
          output = fmt("<agentTool>🤖 Agent result: %s</agentTool>", vim.inspect(data))
        end
      else
        output = fmt("<agentTool>🤖 Agent result: %s</agentTool>", tostring(data))
      end

      local user_msg = output:gsub("<agentTool>", ""):gsub("</agentTool>", "")
      chat:add_tool_output(self, output, user_msg)
    end,

    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      if not chat then
        log:error("[Agent Tool] No chat context available for error handling")
        return
      end

      local errors = vim.iter(stderr):flatten():join("\n")
      local error_output = fmt(
        [[❌ **Agent Tool Error:**
```
%s
```

The AI agent encountered an error during tree of thoughts reasoning.]],
        errors
      )

      chat:add_tool_output(self, error_output)
    end,

    rejected = function(self, agent, cmd)
      local chat = agent.chat
      if not chat then
        return
      end
      chat:add_tool_output(self, "**Agent Tool**: The user declined to execute the agent operation")
    end,
  },
}