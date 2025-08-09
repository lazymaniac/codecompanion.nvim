local TreeNode = {}
TreeNode.__index = TreeNode

function TreeNode:new(content, parent, depth)
  local node = {
    id = string.format("node_%d_%d", os.time(), math.random(1000, 9999)),
    content = content or "",
    parent = parent,
    children = {},
    depth = depth or 0,
    score = 0,
    created_at = os.time(),
    completed = false,
    metadata = {},
  }
  setmetatable(node, TreeNode)
  return node
end

function TreeNode:add_child(content)
  local child = TreeNode:new(content, self, self.depth + 1)
  table.insert(self.children, child)
  return child
end

function TreeNode:get_path()
  local path = {}
  local current = self
  while current do
    table.insert(path, 1, current)
    current = current.parent
  end
  return path
end

function TreeNode:is_leaf()
  return #self.children == 0
end

function TreeNode:get_siblings()
  if not self.parent then
    return {}
  end
  local siblings = {}
  for _, child in ipairs(self.parent.children) do
    if child.id ~= self.id then
      table.insert(siblings, child)
    end
  end
  return siblings
end

-- TreeOfThoughts: Main reasoning system manager
local TreeOfThoughts = {}
TreeOfThoughts.__index = TreeOfThoughts

function TreeOfThoughts:new(initial_problem)
  local tot = {
    root = TreeNode:new(initial_problem or "Initial Problem"),
    current_nodes = {},
    completed_paths = {},
    max_depth = 10,
    beam_width = 3,
    evaluation_fn = nil,
    search_strategy = "best_first",
  }
  setmetatable(tot, TreeOfThoughts)
  tot.current_nodes = { tot.root }
  return tot
end

-- Add multiple reasoning branches from a node
function TreeOfThoughts:branch(node, thoughts)
  local new_nodes = {}
  for _, thought in ipairs(thoughts) do
    local child = node:add_child(thought)
    child.score = self:evaluate_thought(child)
    table.insert(new_nodes, child)
  end
  return new_nodes
end

-- Evaluation system for thoughts and paths
function TreeOfThoughts:evaluate_thought(node)
  if self.evaluation_fn then
    return self.evaluation_fn(node)
  end

  local score = 3.0 -- Base score

  -- Content quality scoring
  local content_len = #node.content
  if content_len > 100 then
    score = score + 1.0
  elseif content_len > 50 then
    score = score + 0.5
  end

  score = score - (node.depth * 0.1)

  -- Path diversity bonus
  local siblings = node:get_siblings()
  if #siblings > 0 then
    score = score + (#siblings * 0.1)
  end

  -- Completeness bonus
  if node.completed then
    score = score + 1.0
  end

  -- Add small random factor for tie-breaking
  score = score + (math.random() * 0.1)

  return math.max(0, score) -- Ensure non-negative
end

function TreeOfThoughts:evaluate_path(path)
  local total_score = 0
  for _, node in ipairs(path) do
    total_score = total_score + node.score
  end
  return total_score / #path
end

-- Search algorithms for tree exploration
function TreeOfThoughts:explore_breadth_first(max_iterations)
  max_iterations = max_iterations or 10
  local iterations = 0

  while #self.current_nodes > 0 and iterations < max_iterations do
    local next_nodes = {}

    for _, node in ipairs(self.current_nodes) do
      if node.depth < self.max_depth then
        -- Only explore nodes that have manually added children
        if #node.children > 0 then
          for _, child in ipairs(node.children) do
            table.insert(next_nodes, child)
          end
        else
          -- Leaf nodes with no children are considered completed paths
          node.completed = true
          table.insert(self.completed_paths, node:get_path())
        end
      else
        node.completed = true
        table.insert(self.completed_paths, node:get_path())
      end
    end

    self.current_nodes = next_nodes
    iterations = iterations + 1
  end
end

function TreeOfThoughts:explore_best_first(max_iterations)
  max_iterations = max_iterations or 10
  local iterations = 0

  while #self.current_nodes > 0 and iterations < max_iterations do
    -- Sort nodes by score (best first)
    table.sort(self.current_nodes, function(a, b)
      return a.score > b.score
    end)

    -- Take only top beam_width nodes
    local selected_nodes = {}
    for i = 1, math.min(self.beam_width, #self.current_nodes) do
      table.insert(selected_nodes, self.current_nodes[i])
    end

    local next_nodes = {}
    for _, node in ipairs(selected_nodes) do
      if node.depth < self.max_depth then
        -- Only explore nodes that have manually added children
        if #node.children > 0 then
          for _, child in ipairs(node.children) do
            table.insert(next_nodes, child)
          end
        else
          -- Leaf nodes with no children are considered completed paths
          node.completed = true
          table.insert(self.completed_paths, node:get_path())
        end
      else
        node.completed = true
        table.insert(self.completed_paths, node:get_path())
      end
    end

    self.current_nodes = next_nodes
    iterations = iterations + 1
  end
end

-- Find the best reasoning path
function TreeOfThoughts:get_best_path()
  if #self.completed_paths == 0 then
    -- If no completed paths, return best current path
    if #self.current_nodes > 0 then
      table.sort(self.current_nodes, function(a, b)
        return a.score > b.score
      end)
      return self.current_nodes[1]:get_path()
    end
    return { self.root }
  end

  local best_path = nil
  local best_score = -math.huge

  for _, path in ipairs(self.completed_paths) do
    local score = self:evaluate_path(path)
    if score > best_score then
      best_score = score
      best_path = path
    end
  end

  return best_path
end

-- Utility functions
function TreeOfThoughts:print_tree(node, indent)
  node = node or self.root
  indent = indent or 0

  local prefix = string.rep("  ", indent)
  print(string.format("%s[%.2f] %s", prefix, node.score, node.content))

  for _, child in ipairs(node.children) do
    self:print_tree(child, indent + 1)
  end
end

function TreeOfThoughts:print_path(path)
  print("=== Reasoning Path ===")
  for i, node in ipairs(path) do
    print(string.format("Step %d [Score: %.2f]: %s", i, node.score, node.content))
  end
  print("=====================")
end

return {
  TreeNode = TreeNode,
  TreeOfThoughts = TreeOfThoughts,
}
