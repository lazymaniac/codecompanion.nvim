local log = require("codecompanion.utils.log")
local fmt = string.format

local function create_tree_node(id, parent_id, content, evaluation, depth)
  local node = {
    id = id,
    parent_id = parent_id,
    content = content,
    evaluation = evaluation or "pending", -- pending, valid, partially_valid, invalid
    depth = depth or 0,
    children = {},
    created_at = os.time(),
  }
  log:debug(
    "[Tree of Thoughts Agent] Created node: id=%s, parent=%s, depth=%d, evaluation=%s",
    id,
    parent_id or "nil",
    depth or 0,
    evaluation or "pending"
  )
  return node
end

local function add_node_to_tree(tree, node)
  tree.nodes[node.id] = node
  if node.parent_id and tree.nodes[node.parent_id] then
    table.insert(tree.nodes[node.parent_id].children, node.id)
  end
  tree.node_count = tree.node_count + 1
  log:debug("[Tree of Thoughts Agent] Added node %s to tree (total nodes: %d)", node.id, tree.node_count)
end

local function create_empty_tree(root_goal)
  log:debug("[Tree of Thoughts Agent] Creating new tree with goal: %s", root_goal)
  local tree = {
    nodes = {},
    node_count = 0,
    root_id = "root",
    goal = root_goal,
    created_at = os.time(),
  }

  local root_node = create_tree_node("root", nil, root_goal, "pending", 0)
  add_node_to_tree(tree, root_node)

  log:debug("[Tree of Thoughts Agent] Tree created successfully with root node")
  return tree
end

local function serialize_tree_for_llm(tree)
  log:debug("[Tree of Thoughts Agent] Serializing tree for LLM view (nodes: %d)", tree.node_count)

  local function serialize_node(node_id, indent)
    local node = tree.nodes[node_id]
    if not node then
      log:debug("[Tree of Thoughts Agent] Warning: Node %s not found during serialization", node_id)
      return ""
    end

    local result = string.rep("  ", indent) .. fmt("Node %s [%s]: %s\n", node.id, node.evaluation, node.content)

    for _, child_id in ipairs(node.children) do
      result = result .. serialize_node(child_id, indent + 1)
    end

    return result
  end

  local serialized = fmt("Tree of Thoughts (Goal: %s)\n", tree.goal)
  serialized = serialized .. fmt("Total nodes: %d\n\n", tree.node_count)
  serialized = serialized .. serialize_node(tree.root_id, 0)

  log:debug("[Tree of Thoughts Agent] Tree serialization complete")
  return serialized
end

local agent_state = {
  current_tree = nil,
  mode = "REASON", -- REASON or EXECUTE
  execution_history = {},
  session_id = nil,
}

local function handle_reason_mode(args)
  log:debug("[Tree of Thoughts Agent] Entering REASON mode with action: %s", args.action)
  log:debug(
    "[Tree of Thoughts Agent] Current state - session_id: %s, tree_exists: %s, mode: %s",
    agent_state.session_id or "nil",
    agent_state.current_tree and "true" or "false",
    agent_state.mode
  )

  if args.action == "initialize" then
    log:debug("[Tree of Thoughts Agent] Initializing new session with goal: %s", args.goal or "nil")

    if not args.goal then
      log:debug("[Tree of Thoughts Agent] Initialize failed: no goal provided")
      return { status = "error", data = "Goal is required for initialization" }
    end

    agent_state.session_id = tostring(os.time())
    agent_state.current_tree = create_empty_tree(args.goal)
    agent_state.mode = "REASON"
    agent_state.execution_history = {} -- Reset execution history

    log:debug(
      "[Tree of Thoughts Agent] Session initialized successfully - session_id: %s, goal: %s",
      agent_state.session_id,
      args.goal
    )

    return {
      status = "success",
      data = fmt(
        "Tree of Thoughts session initialized.\nGoal: %s\nSession ID: %s\n\nYou can now:\n- add_node: Create new thought branches\n- evaluate_node: Assess existing nodes\n- vote_best_path: Select the optimal approach\n- view_tree: See current tree structure",
        args.goal,
        agent_state.session_id
      ),
    }
  elseif args.action == "add_node" then
    log:debug("[Tree of Thoughts Agent] Adding node: id=%s, parent=%s", args.node_id or "nil", args.parent_id or "nil")

    if not agent_state.current_tree then
      log:debug("[Tree of Thoughts Agent] Add node failed: no active tree")
      return { status = "error", data = "No active tree. Initialize first." }
    end

    if not args.node_id then
      log:debug("[Tree of Thoughts Agent] Add node failed: no node_id provided")
      return { status = "error", data = "node_id is required" }
    end

    if not args.content then
      log:debug("[Tree of Thoughts Agent] Add node failed: no content provided")
      return { status = "error", data = "content is required" }
    end

    if args.parent_id and not agent_state.current_tree.nodes[args.parent_id] then
      log:debug("[Tree of Thoughts Agent] Add node failed: parent node %s not found", args.parent_id)
      return { status = "error", data = fmt("Parent node '%s' not found", args.parent_id) }
    end

    local parent_depth = (args.parent_id and agent_state.current_tree.nodes[args.parent_id])
        and agent_state.current_tree.nodes[args.parent_id].depth + 1
      or 0

    local node = create_tree_node(args.node_id, args.parent_id, args.content, "pending", parent_depth)
    add_node_to_tree(agent_state.current_tree, node)

    log:debug("[Tree of Thoughts Agent] Node added successfully: %s", args.node_id)

    return {
      status = "success",
      data = fmt(
        "Added node '%s' to tree.\nContent: %s\nParent: %s",
        args.node_id,
        args.content,
        args.parent_id or "root"
      ),
    }
  elseif args.action == "evaluate_node" then
    log:debug(
      "[Tree of Thoughts Agent] Evaluating node: id=%s, evaluation=%s",
      args.node_id or "nil",
      args.evaluation or "nil"
    )

    if not agent_state.current_tree then
      log:debug("[Tree of Thoughts Agent] Evaluate node failed: no active tree")
      return { status = "error", data = "No active tree. Initialize first." }
    end

    if not args.node_id then
      log:debug("[Tree of Thoughts Agent] Evaluate node failed: no node_id provided")
      return { status = "error", data = "node_id is required" }
    end

    if not agent_state.current_tree.nodes[args.node_id] then
      log:debug("[Tree of Thoughts Agent] Evaluate node failed: node %s not found", args.node_id)
      return { status = "error", data = fmt("Node '%s' not found", args.node_id) }
    end

    if not args.evaluation then
      log:debug("[Tree of Thoughts Agent] Evaluate node failed: no evaluation provided")
      return { status = "error", data = "evaluation is required (valid, partially_valid, invalid)" }
    end

    local old_evaluation = agent_state.current_tree.nodes[args.node_id].evaluation
    agent_state.current_tree.nodes[args.node_id].evaluation = args.evaluation

    log:debug(
      "[Tree of Thoughts Agent] Node evaluation updated: %s (%s -> %s)",
      args.node_id,
      old_evaluation,
      args.evaluation
    )

    return {
      status = "success",
      data = fmt("Node '%s' evaluated as: %s\nReasoning: %s", args.node_id, args.evaluation, args.reasoning or ""),
    }
  elseif args.action == "view_tree" then
    log:debug("[Tree of Thoughts Agent] Viewing tree structure")

    if not agent_state.current_tree then
      log:debug("[Tree of Thoughts Agent] View tree failed: no active tree")
      return { status = "error", data = "No active tree. Initialize first." }
    end

    log:debug(
      "[Tree of Thoughts Agent] Tree view requested - nodes: %d, goal: %s",
      agent_state.current_tree.node_count,
      agent_state.current_tree.goal
    )

    return {
      status = "success",
      data = serialize_tree_for_llm(agent_state.current_tree),
    }
  elseif args.action == "vote_best_path" then
    if not agent_state.current_tree then
      return { status = "error", data = "No active tree" }
    end

    agent_state.mode = "EXECUTE"
    log:debug("[Tree of Thoughts Agent] Switching to EXECUTE mode. Best path: %s", args.chosen_path)

    return {
      status = "success",
      data = fmt(
        "Best path selected: %s\nReasoning: %s\n\nSwitching to EXECUTE mode. Define your task now.",
        args.chosen_path,
        args.reasoning or ""
      ),
    }
  elseif args.action == "reflect" then
    -- Allow reflection in REASON mode for post-execution analysis
    local reflection = {
      timestamp = os.time(),
      content = args.reflection,
      lessons_learned = args.lessons_learned or {},
      next_steps = args.next_steps or {},
    }

    if #agent_state.execution_history > 0 then
      agent_state.execution_history[#agent_state.execution_history].reflection = reflection
    end

    log:debug("[Tree of Thoughts Agent] Reflection recorded in REASON mode")

    return {
      status = "success",
      data = fmt(
        "Reflection recorded: %s\nLessons learned: %s\nNext steps: %s\n\nYou can now continue reasoning or start a new cycle.",
        reflection.content,
        table.concat(reflection.lessons_learned, ", "),
        table.concat(reflection.next_steps, ", ")
      ),
    }
  end

  return { status = "error", data = "Unknown REASON action: " .. (args.action or "nil") }
end

local function handle_execute_mode(args)
  log:debug(
    "[Tree of Thoughts Agent] EXECUTE mode - action: %s, history_count: %d",
    args.action,
    #agent_state.execution_history
  )

  if args.action == "define_task" then
    log:debug("[Tree of Thoughts Agent] Defining task: %s", args.task_description or "nil")

    if not args.task_description then
      log:debug("[Tree of Thoughts Agent] Define task failed: no task_description provided")
      return { status = "error", data = "task_description is required" }
    end

    local task = {
      id = tostring(os.time()),
      description = args.task_description,
      steps = args.steps or {},
      created_at = os.time(),
      status = "defined",
    }

    table.insert(agent_state.execution_history, task)
    log:debug("[Tree of Thoughts Agent] Task defined with ID %s, steps: %d", task.id, #task.steps)

    return {
      status = "success",
      data = fmt(
        "Task defined: %s\nSteps: %s\n\nTask is ready for execution. Use other available tools to complete it, then call 'complete_task' when done.",
        task.description,
        table.concat(task.steps, ", ")
      ),
    }
  elseif args.action == "complete_task" then
    log:debug("[Tree of Thoughts Agent] Completing task, result: %s", args.result and "provided" or "nil")

    if #agent_state.execution_history == 0 then
      log:debug("[Tree of Thoughts Agent] Complete task failed: no active tasks")
      return { status = "error", data = "No active task to complete" }
    end

    if not args.result then
      log:debug("[Tree of Thoughts Agent] Complete task failed: no result provided")
      return { status = "error", data = "result is required" }
    end

    local current_task = agent_state.execution_history[#agent_state.execution_history]
    local old_status = current_task.status
    current_task.status = "completed"
    current_task.result = args.result
    current_task.completed_at = os.time()

    agent_state.mode = "REASON"
    log:debug(
      "[Tree of Thoughts Agent] Task %s completed (%s -> %s), mode switched: EXECUTE -> REASON",
      current_task.id,
      old_status,
      current_task.status
    )

    return {
      status = "success",
      data = fmt(
        "Task completed: %s\nResult: %s\n\nSwitching back to REASON mode for reflection and next steps.",
        current_task.description,
        args.result
      ),
    }
  elseif args.action == "reflect" then
    log:debug("[Tree of Thoughts Agent] Recording reflection in EXECUTE mode")

    if not args.reflection then
      log:debug("[Tree of Thoughts Agent] Reflect failed: no reflection content provided")
      return { status = "error", data = "reflection is required" }
    end

    local reflection = {
      timestamp = os.time(),
      content = args.reflection,
      lessons_learned = args.lessons_learned or {},
      next_steps = args.next_steps or {},
    }

    if #agent_state.execution_history > 0 then
      agent_state.execution_history[#agent_state.execution_history].reflection = reflection
      log:debug(
        "[Tree of Thoughts Agent] Reflection attached to task %s, lessons: %d, next_steps: %d",
        agent_state.execution_history[#agent_state.execution_history].id,
        #reflection.lessons_learned,
        #reflection.next_steps
      )
    else
      log:debug("[Tree of Thoughts Agent] Reflection recorded without active task")
    end

    return {
      status = "success",
      data = fmt(
        "Reflection recorded: %s\nLessons learned: %s\nNext steps: %s",
        reflection.content,
        table.concat(reflection.lessons_learned, ", "),
        table.concat(reflection.next_steps, ", ")
      ),
    }
  end

  return { status = "error", data = "Unknown EXECUTE action: " .. (args.action or "nil") }
end

---@class CodeCompanion.Tool.Agent: CodeCompanion.Agent.Tool
return {
  name = "agent",
  cmds = {
    ---Execute the agent commands
    ---@param self CodeCompanion.Tool.Agent
    ---@param args table The arguments from the LLM's tool call
    ---@param input? any The output from the previous function call
    ---@return { status: "success"|"error", data: string }
    function(self, args, input)
      log:debug(
        "[Tree of Thoughts Agent] Tool invoked - mode: %s, action: %s, session: %s",
        agent_state.mode,
        args.action or "nil",
        agent_state.session_id or "none"
      )
      log:debug("[Tree of Thoughts Agent] Args received: %s", vim.inspect(args))

      local result
      if agent_state.mode == "REASON" then
        result = handle_reason_mode(args)
      elseif agent_state.mode == "EXECUTE" then
        result = handle_execute_mode(args)
      else
        log:debug("[Tree of Thoughts Agent] ERROR: Invalid mode: %s", agent_state.mode)
        result = { status = "error", data = "Invalid agent mode: " .. agent_state.mode }
      end

      log:debug("[Tree of Thoughts Agent] Command completed - status: %s, mode: %s", result.status, agent_state.mode)
      return result
    end,
  },
  schema = {
    type = "function",
    ["function"] = {
      name = "agent",
      description = "Tree of Thoughts reasoning agent that alternates between REASON and EXECUTE modes to solve complex problems systematically.",
      parameters = {
        type = "object",
        properties = {
          action = {
            type = "string",
            description = "The action to perform. REASON mode: 'initialize', 'add_node', 'evaluate_node', 'view_tree', 'vote_best_path', 'reflect'. EXECUTE mode: 'define_task', 'complete_task', 'reflect'",
          },
          goal = {
            type = "string",
            description = "The overall goal (required for 'initialize' action)",
          },
          node_id = {
            type = "string",
            description = "Unique identifier for the node (required for 'add_node', 'evaluate_node')",
          },
          parent_id = {
            type = "string",
            description = "Parent node ID (required for 'add_node')",
          },
          content = {
            type = "string",
            description = "The thought content for the node (required for 'add_node')",
          },
          evaluation = {
            type = "string",
            description = "Node evaluation: 'valid', 'partially_valid', 'invalid' (required for 'evaluate_node')",
          },
          reasoning = {
            type = "string",
            description = "Explanation for evaluation or path choice",
          },
          chosen_path = {
            type = "string",
            description = "The selected best path (required for 'vote_best_path')",
          },
          task_description = {
            type = "string",
            description = "Description of the task to execute (required for 'define_task')",
          },
          steps = {
            type = "array",
            items = { type = "string" },
            description = "List of steps for the task (optional for 'define_task')",
          },
          result = {
            type = "string",
            description = "The result of task execution (required for 'complete_task')",
          },
          reflection = {
            type = "string",
            description = "Reflection on the execution (required for 'reflect')",
          },
          lessons_learned = {
            type = "array",
            items = { type = "string" },
            description = "Lessons learned from execution (optional for 'reflect')",
          },
          next_steps = {
            type = "array",
            items = { type = "string" },
            description = "Suggested next steps (optional for 'reflect')",
          },
        },
        required = { "action" },
        additionalProperties = false,
      },
      strict = true,
    },
  },
  system_prompt = fmt(
    [[# Tree of Thoughts Agent

## OVERVIEW
You are a Tree of Thoughts reasoning agent that operates in two alternating modes to solve complex problems systematically:

1. **REASON Mode**: Generate and evaluate multiple thought processes using a tree structure
2. **EXECUTE Mode**: Implement selected plans step by step using available tools

## WORKFLOW
1. User provides a problem → Initialize tree with goal
2. REASON: Create multiple solution branches, evaluate each path
3. Vote on best approach → Switch to EXECUTE mode
4. EXECUTE: Define and complete specific tasks using other tools
5. Reflect on results → Return to REASON mode for next iteration
6. Repeat until problem is solved

## REASON MODE ACTIONS

### initialize
- **Purpose**: Start a new Tree of Thoughts session
- **Required**: goal
- **Usage**: Always start here with the user's problem

### add_node
- **Purpose**: Create new thought branches in the tree
- **Required**: node_id, parent_id, content
- **Usage**: Explore different solution paths node by node

### evaluate_node
- **Purpose**: Assess the validity of thought paths
- **Required**: node_id, evaluation ("valid", "partially_valid", "invalid")
- **Optional**: reasoning
- **Usage**: Critically evaluate each branch you create

### view_tree
- **Purpose**: Display current tree structure
- **Usage**: Review your thinking progress

### vote_best_path
- **Purpose**: Select optimal approach and switch to EXECUTE mode
- **Required**: chosen_path
- **Optional**: reasoning
- **Usage**: After exploring branches, choose the best one

## EXECUTE MODE ACTIONS

### define_task
- **Purpose**: Create specific, actionable task from chosen path
- **Required**: task_description
- **Optional**: steps
- **Usage**: Break down the chosen approach into executable steps

### complete_task
- **Purpose**: Mark task as done and provide results
- **Required**: result
- **Usage**: After using other tools to complete the task

### reflect
- **Purpose**: Analyze execution results and learn (available in both modes)
- **Required**: reflection
- **Optional**: lessons_learned, next_steps
- **Usage**: After task completion or during reasoning for analysis

## RULES

1. **Always start with 'initialize'** when given a new problem
2. **Create multiple branches** - explore at least 2-3 different approaches
3. **Evaluate every node** you create - be critical and thorough
4. **Use other tools during EXECUTE mode** - this agent coordinates, doesn't replace other tools
5. **Reflect after each execution** - learn from results to improve next reasoning
6. **Be flexible** - create any tree structure that helps solve the problem
7. **Stay general purpose** - don't assume specific domains or approaches

## CURRENT MODE
The agent starts in REASON mode. Mode switches happen automatically:
- REASON → EXECUTE: When you vote for best path
- EXECUTE → REASON: When you complete a task

## INTEGRATION
- Use this agent to **plan and coordinate** complex multi-step problems
- Use **other available tools** during EXECUTE mode to actually perform work
- The agent **tracks your reasoning process** and helps maintain context across iterations

Remember: This tool helps you think systematically, not replace other tools. Use it to organize your approach, then execute with appropriate specialized tools.]]
  ),
  handlers = {
    ---@param agent CodeCompanion.Agent The tool object
    ---@return nil
    on_exit = function(agent)
      log:debug(
        "[Tree of Thoughts Agent] Session ended - final_mode: %s, session: %s, tasks: %d, tree_nodes: %d",
        agent_state.mode,
        agent_state.session_id or "none",
        #agent_state.execution_history,
        agent_state.current_tree and agent_state.current_tree.node_count or 0
      )
    end,
  },
  output = {
    ---@param self CodeCompanion.Tool.Agent
    ---@param agent CodeCompanion.Agent
    ---@param cmd table The command that was executed
    ---@param stdout table The output from the command
    success = function(self, agent, cmd, stdout)
      local chat = agent.chat
      local result = vim.iter(stdout):flatten():join("\n")

      local mode_indicator = fmt("[%s MODE]", agent_state.mode)
      local user_output = fmt("%s Tree of Thoughts Agent", mode_indicator)
      local llm_output = fmt("%s %s", mode_indicator, result)

      log:debug(
        "[Tree of Thoughts Agent] Success output generated - mode: %s, output_length: %d",
        agent_state.mode,
        #result
      )
      log:debug(
        "[Tree of Thoughts Agent] LLM output: %s",
        llm_output:sub(1, 200) .. (#llm_output > 200 and "..." or "")
      )

      chat:add_tool_output(self, llm_output, user_output)
    end,

    ---@param self CodeCompanion.Tool.Agent
    ---@param agent CodeCompanion.Agent
    ---@param cmd table
    ---@param stderr table The error output from the command
    error = function(self, agent, cmd, stderr)
      local chat = agent.chat
      local errors = vim.iter(stderr):flatten():join("\n")
      log:debug(
        "[Tree of Thoughts Agent] Error occurred - mode: %s, session: %s",
        agent_state.mode,
        agent_state.session_id or "none"
      )
      log:debug("[Tree of Thoughts Agent] Error details: %s", errors)

      local error_output = fmt("[ERROR] Tree of Thoughts Agent (%s MODE): %s", agent_state.mode, errors)
      chat:add_tool_output(self, error_output)
    end,

    ---@param self CodeCompanion.Tool.Agent
    ---@param agent CodeCompanion.Agent
    ---@return nil|string
    prompt = function(self, agent)
      log:debug(
        "[Tree of Thoughts Agent] Prompting user for approval - mode: %s, action: %s",
        agent_state.mode,
        self.args and self.args.action or "unknown"
      )
      return fmt(
        "Use Tree of Thoughts Agent in %s mode (%s)?",
        agent_state.mode,
        self.args and self.args.action or "unknown action"
      )
    end,

    ---@param self CodeCompanion.Tool.Agent
    ---@param agent CodeCompanion.Agent
    ---@param cmd table
    ---@return nil
    rejected = function(self, agent, cmd)
      local chat = agent.chat
      log:debug(
        "[Tree of Thoughts Agent] User rejected execution - mode: %s, action: %s",
        agent_state.mode,
        self.args and self.args.action or "unknown"
      )
      chat:add_tool_output(
        self,
        fmt(
          "Tree of Thoughts Agent (%s MODE): User declined to execute %s",
          agent_state.mode,
          self.args and self.args.action or "action"
        )
      )
    end,
  },
}
