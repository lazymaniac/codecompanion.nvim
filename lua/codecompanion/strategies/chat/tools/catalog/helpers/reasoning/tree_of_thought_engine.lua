---@class CodeCompanion.TreeOfThoughtEngine

local ReasoningVisualizer = require("codecompanion.strategies.chat.tools.catalog.helpers.reasoning_visualizer")
local ToT = require("codecompanion.strategies.chat.tools.catalog.helpers.reasoning.tree_of_thoughts")
local log = require("codecompanion.utils.log")
local fmt = string.format

local TreeOfThoughtEngine = {}

local Actions = {}

function Actions.initialize(args, agent_state)
  log:debug("[Tree of Thoughts Engine] Initializing with problem: %s", args.problem)

  agent_state.session_id = tostring(os.time())
  agent_state.current_instance = ToT.TreeOfThoughts:new(args.problem)
  agent_state.current_instance.agent_type = "Tree of Thoughts Agent"

  -- Set search parameters
  agent_state.current_instance.max_depth = args.max_depth or 6
  agent_state.current_instance.beam_width = args.beam_width or 3
  agent_state.current_instance.search_strategy = args.search_strategy or "best_first"

  -- Add interface methods for base class compatibility
  agent_state.current_instance.get_element = function(self, id)
    if self.nodes then
      for _, node in ipairs(self.nodes) do
        if node.id == id then
          return node
        end
      end
    end
    return nil
  end

  agent_state.current_instance.update_element_score = function(self, id, boost)
    local node = self:get_element(id)
    if node then
      node.value = (node.value or 0) + boost
      return true
    end
    return false
  end

  return {
    status = "success",
    data = fmt(
      [[# Tree of Thoughts Initialized

**Problem:** %s
**Session ID:** %s
**Max Depth:** %d
**Beam Width:** %d
**Search Strategy:** %s

The tree is ready to explore multiple reasoning paths for your problem.]],
      args.problem,
      agent_state.session_id,
      agent_state.current_instance.max_depth,
      agent_state.current_instance.beam_width,
      agent_state.current_instance.search_strategy
    ),
  }
end

function Actions.explore(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active tree. Initialize first." }
  end

  log:debug("[Tree of Thoughts Engine] Exploring tree with strategy: %s", agent_state.current_instance.search_strategy)

  local iterations = args.iterations or 5

  if agent_state.current_instance.search_strategy == "breadth_first" then
    agent_state.current_instance:explore_breadth_first(iterations)
  else
    agent_state.current_instance:explore_best_first(iterations)
  end

  local total_nodes = 0
  if agent_state.current_instance.nodes then
    for _ in pairs(agent_state.current_instance.nodes) do
      total_nodes = total_nodes + 1
    end
  end

  return {
    status = "success",
    data = fmt(
      [[# Tree Exploration Complete

**Strategy Used:** %s
**Iterations:** %d
**Total Nodes:** %d
**Max Depth:** %d

Use 'get_best_path' to see the current best reasoning path, or 'view_tree' to see the complete structure.]],
      agent_state.current_instance.search_strategy,
      iterations,
      total_nodes,
      agent_state.current_instance.max_depth
    ),
  }
end

function Actions.add_thoughts(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active tree. Initialize first." }
  end

  log:debug("[Tree of Thoughts Engine] Adding thoughts to root node")

  -- Use the branch method to add thoughts to the root node
  local new_nodes = agent_state.current_instance:branch(agent_state.current_instance.root, args.thoughts)

  if not new_nodes or #new_nodes == 0 then
    return {
      status = "error",
      data = "Failed to add thoughts to tree.",
    }
  end

  return {
    status = "success",
    data = fmt("**Add Thoughts:** %d new nodes", #new_nodes),
  }
end

function Actions.get_best_path(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active tree. Initialize first." }
  end

  log:debug("[Tree of Thoughts Engine] Getting best path")

  local best_path = agent_state.current_instance:get_best_path()
  if not best_path or #best_path == 0 then
    return {
      status = "error",
      data = "No complete paths found. Try exploring the tree more or adding thoughts to leaf nodes.",
    }
  end

  local path_description = {}
  for i, node in ipairs(best_path) do
    table.insert(path_description, fmt("**Step %d**: %s (Score: %.2f)", i, node.content, node.value or 0))
  end

  return {
    status = "success",
    data = fmt("**Best Path:** %d steps, score %.2f", #best_path, best_path[#best_path].value or 0),
  }
end

function Actions.view_tree(args, agent_state)
  if not agent_state.current_instance then
    return { status = "error", data = "No active tree. Initialize first." }
  end

  log:debug("[Tree of Thoughts Engine] Viewing tree structure")

  -- Use the new reasoning visualizer
  local config = {
    show_scores = true,
    show_timestamps = args.show_timestamps or false,
    show_metadata = args.show_metadata or false,
    max_content_length = args.max_content_length or 60,
    use_unicode = args.use_unicode ~= false, -- Default to true
  }

  local tree_view = ""

  -- If we have a root node, visualize from there
  if agent_state.current_instance.root then
    tree_view = ReasoningVisualizer.visualize_tree(agent_state.current_instance.root, config)
  else
    -- Fallback to original method if no root
    local tree_lines = {}
    local original_print = print
    print = function(line)
      table.insert(tree_lines, line or "")
    end

    agent_state.current_instance:print_tree()
    print = original_print

    tree_view = table.concat(tree_lines, "\n")
  end

  return {
    status = "success",
    data = tree_view,
  }
end

function TreeOfThoughtEngine.get_config()
  return {
    agent_type = "Tree of Thoughts Agent",
    tool_name = "tree_of_thoughts_agent",
    description = "Tree of Thoughts reasoning agent that systematically explores multiple solution paths for complex problems using tree-based search algorithms.",
    actions = Actions,
    validation_rules = {
      initialize = { "problem" },
      explore = {},
      add_thoughts = { "thoughts" },
      evaluate_path = { "path_nodes" },
      get_best_path = {},
      view_tree = {},
    },
    parameters = {
      type = "object",
      properties = {
        action = {
          type = "string",
          description = "The tree action to perform: 'initialize', 'explore', 'add_thoughts', 'evaluate_path', 'get_best_path', 'view_tree'",
        },
        problem = {
          type = "string",
          description = "The problem to solve using tree of thoughts (required for 'initialize' action)",
        },
        thoughts = {
          type = "array",
          items = { type = "string" },
          description = "Array of thought strings to add to a node (required for 'add_thoughts')",
        },
        max_depth = {
          type = "number",
          description = "Maximum tree depth for exploration (default: 6, for 'initialize')",
        },
        beam_width = {
          type = "number",
          description = "Number of best nodes to keep at each level (default: 3, for 'initialize')",
        },
        search_strategy = {
          type = "string",
          description = "Search strategy: 'breadth_first' or 'best_first' (default: 'best_first', for 'initialize')",
        },
        iterations = {
          type = "number",
          description = "Number of exploration iterations to run (default: 5, for 'explore')",
        },
      },
      required = { "action" },
      additionalProperties = false,
    },
    system_prompt_config = function()
      local UnifiedReasoningPrompt =
        require("codecompanion.strategies.chat.tools.catalog.helpers.unified_reasoning_prompt")
      return UnifiedReasoningPrompt.tree_of_thoughts_config()
    end,
  }
end

return TreeOfThoughtEngine
