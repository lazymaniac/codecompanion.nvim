-- Graph of Thoughts Reasoning System in Lua

local function generate_id()
  return tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
end

-- ThoughtNode Class
local ThoughtNode = {}
ThoughtNode.__index = ThoughtNode

function ThoughtNode.new(content, id)
  local self = setmetatable({}, ThoughtNode)
  self.id = id or generate_id()
  self.content = content or ""
  self.state = "pending" -- pending, processing, completed, failed
  self.score = 0.0
  self.confidence = 0.0
  self.dependencies = {} -- input dependencies
  self.dependents = {} -- nodes that depend on this
  self.results = {} -- outputs/results from processing
  self.metadata = {}
  self.created_at = os.time()
  self.updated_at = os.time()
  return self
end

function ThoughtNode:update_state(new_state)
  self.state = new_state
  self.updated_at = os.time()
end

function ThoughtNode:set_score(score, confidence)
  self.score = score or self.score
  self.confidence = confidence or self.confidence
  self.updated_at = os.time()
end

function ThoughtNode:add_result(result)
  table.insert(self.results, result)
  self.updated_at = os.time()
end

function ThoughtNode:is_ready()
  return self.state == "pending"
end

-- Edge Class
local Edge = {}
Edge.__index = Edge

function Edge.new(source_id, target_id, weight, relationship_type)
  local self = setmetatable({}, Edge)
  self.source = source_id
  self.target = target_id
  self.weight = weight or 1.0
  self.type = relationship_type or "depends_on"
  self.created_at = os.time()
  return self
end

-- GraphOfThoughts Class
local GraphOfThoughts = {}
GraphOfThoughts.__index = GraphOfThoughts

function GraphOfThoughts.new()
  local self = setmetatable({}, GraphOfThoughts)
  self.nodes = {} -- id -> ThoughtNode
  self.edges = {} -- source_id -> {target_id -> Edge}
  self.reverse_edges = {} -- target_id -> {source_id -> Edge}
  self.execution_queue = {}
  self.completed_nodes = {}
  self.failed_nodes = {}
  return self
end

-- Node Management
function GraphOfThoughts:add_node(content, id)
  local node = ThoughtNode.new(content, id)
  self.nodes[node.id] = node
  self.edges[node.id] = {}
  self.reverse_edges[node.id] = {}
  return node.id
end

function GraphOfThoughts:remove_node(node_id)
  if not self.nodes[node_id] then
    return false
  end

  -- Remove all edges involving this node
  for target_id, _ in pairs(self.edges[node_id]) do
    self:remove_edge(node_id, target_id)
  end
  for source_id, _ in pairs(self.reverse_edges[node_id]) do
    self:remove_edge(source_id, node_id)
  end

  self.nodes[node_id] = nil
  self.edges[node_id] = nil
  self.reverse_edges[node_id] = nil
  return true
end

function GraphOfThoughts:get_node(node_id)
  return self.nodes[node_id]
end

-- Edge Management
function GraphOfThoughts:add_edge(source_id, target_id, weight, relationship_type)
  if not self.nodes[source_id] or not self.nodes[target_id] then
    return false, "Source or target node does not exist"
  end

  local edge = Edge.new(source_id, target_id, weight, relationship_type)

  -- Add to adjacency lists
  self.edges[source_id][target_id] = edge
  self.reverse_edges[target_id][source_id] = edge

  -- Update node dependencies
  table.insert(self.nodes[target_id].dependencies, source_id)
  table.insert(self.nodes[source_id].dependents, target_id)

  return true
end

function GraphOfThoughts:remove_edge(source_id, target_id)
  if not self.edges[source_id] or not self.edges[source_id][target_id] then
    return false
  end

  -- Remove from adjacency lists
  self.edges[source_id][target_id] = nil
  self.reverse_edges[target_id][source_id] = nil

  -- Update node dependencies
  local target_node = self.nodes[target_id]
  for i, dep_id in ipairs(target_node.dependencies) do
    if dep_id == source_id then
      table.remove(target_node.dependencies, i)
      break
    end
  end

  local source_node = self.nodes[source_id]
  for i, dep_id in ipairs(source_node.dependents) do
    if dep_id == target_id then
      table.remove(source_node.dependents, i)
      break
    end
  end

  return true
end

-- Cycle Detection
function GraphOfThoughts:has_cycle()
  local visited = {}
  local rec_stack = {}

  for node_id, _ in pairs(self.nodes) do
    visited[node_id] = false
    rec_stack[node_id] = false
  end

  local function dfs_cycle_check(node_id)
    visited[node_id] = true
    rec_stack[node_id] = true

    for target_id, _ in pairs(self.edges[node_id]) do
      if not visited[target_id] then
        if dfs_cycle_check(target_id) then
          return true
        end
      elseif rec_stack[target_id] then
        return true
      end
    end

    rec_stack[node_id] = false
    return false
  end

  for node_id, _ in pairs(self.nodes) do
    if not visited[node_id] then
      if dfs_cycle_check(node_id) then
        return true
      end
    end
  end

  return false
end

-- Topological Sort
function GraphOfThoughts:topological_sort()
  local in_degree = {}
  local queue = {}
  local result = {}

  -- Calculate in-degrees
  for node_id, _ in pairs(self.nodes) do
    in_degree[node_id] = #self.nodes[node_id].dependencies
  end

  -- Find nodes with no dependencies
  for node_id, degree in pairs(in_degree) do
    if degree == 0 then
      table.insert(queue, node_id)
    end
  end

  -- Process queue
  while #queue > 0 do
    local current = table.remove(queue, 1)
    table.insert(result, current)

    -- Update dependents
    for target_id, _ in pairs(self.edges[current]) do
      in_degree[target_id] = in_degree[target_id] - 1
      if in_degree[target_id] == 0 then
        table.insert(queue, target_id)
      end
    end
  end

  -- Check if all nodes are included (no cycles)
  if #result ~= self:get_node_count() then
    return nil, "Graph contains cycles"
  end

  return result
end

-- Evaluation System
function GraphOfThoughts:evaluate_node(node_id, evaluation_func)
  local node = self.nodes[node_id]
  if not node then
    return false
  end

  local score, confidence = evaluation_func(node)
  node:set_score(score, confidence)

  return true
end

function GraphOfThoughts:propagate_scores(node_id)
  local node = self.nodes[node_id]
  if not node then
    return
  end

  -- Simple score propagation: weighted average of dependency scores
  for _, dependent_id in ipairs(node.dependents) do
    local dependent = self.nodes[dependent_id]
    if dependent.state == "pending" or dependent.state == "processing" then
      -- Update dependent's score based on this node's completion
      local influence = 0.3 -- configurable influence factor
      dependent.score = dependent.score + (node.score * influence)
    end
  end
end

function GraphOfThoughts:get_best_path(start_id, end_id)
  -- Dijkstra's algorithm for best scoring path
  local distances = {}
  local previous = {}
  local unvisited = {}

  for node_id, _ in pairs(self.nodes) do
    distances[node_id] = math.huge
    previous[node_id] = nil
    unvisited[node_id] = true
  end

  distances[start_id] = 0

  while next(unvisited) do
    -- Find unvisited node with minimum distance
    local current = nil
    local min_dist = math.huge
    for node_id, _ in pairs(unvisited) do
      if distances[node_id] < min_dist then
        min_dist = distances[node_id]
        current = node_id
      end
    end

    if not current or current == end_id then
      break
    end

    unvisited[current] = nil

    -- Update distances to neighbors
    for target_id, edge in pairs(self.edges[current]) do
      if unvisited[target_id] then
        local alt = distances[current] + (1.0 / edge.weight) -- Lower weight = better path
        if alt < distances[target_id] then
          distances[target_id] = alt
          previous[target_id] = current
        end
      end
    end
  end

  -- Reconstruct path
  local path = {}
  local current = end_id
  while current do
    table.insert(path, 1, current)
    current = previous[current]
  end

  return #path > 1 and path or nil
end

-- Utility Functions
function GraphOfThoughts:get_node_count()
  local count = 0
  for _ in pairs(self.nodes) do
    count = count + 1
  end
  return count
end

function GraphOfThoughts:get_pending_count()
  local count = 0
  for _, node in pairs(self.nodes) do
    if node.state == "pending" then
      count = count + 1
    end
  end
  return count
end

function GraphOfThoughts:get_stats()
  local stats = {
    total_nodes = self:get_node_count(),
    pending = 0,
    processing = 0,
    completed = 0,
    failed = 0,
    total_edges = 0,
  }

  for _, node in pairs(self.nodes) do
    stats[node.state] = stats[node.state] + 1
  end

  for _, edges in pairs(self.edges) do
    for _ in pairs(edges) do
      stats.total_edges = stats.total_edges + 1
    end
  end

  return stats
end

-- Serialization
function GraphOfThoughts:serialize()
  local data = {
    nodes = {},
    edges = {},
  }

  for node_id, node in pairs(self.nodes) do
    data.nodes[node_id] = {
      id = node.id,
      content = node.content,
      state = node.state,
      score = node.score,
      confidence = node.confidence,
      results = node.results,
      metadata = node.metadata,
      created_at = node.created_at,
      updated_at = node.updated_at,
    }
  end

  for source_id, targets in pairs(self.edges) do
    for target_id, edge in pairs(targets) do
      table.insert(data.edges, {
        source = edge.source,
        target = edge.target,
        weight = edge.weight,
        type = edge.type,
        created_at = edge.created_at,
      })
    end
  end

  return data
end

function GraphOfThoughts:deserialize(data)
  self.nodes = {}
  self.edges = {}
  self.reverse_edges = {}

  -- Recreate nodes
  for node_id, node_data in pairs(data.nodes) do
    local node = ThoughtNode.new(node_data.content, node_data.id)
    node.state = node_data.state
    node.score = node_data.score
    node.confidence = node_data.confidence
    node.results = node_data.results
    node.metadata = node_data.metadata
    node.created_at = node_data.created_at
    node.updated_at = node_data.updated_at

    self.nodes[node_id] = node
    self.edges[node_id] = {}
    self.reverse_edges[node_id] = {}
  end

  -- Recreate edges
  for _, edge_data in ipairs(data.edges) do
    self:add_edge(edge_data.source, edge_data.target, edge_data.weight, edge_data.type)
  end
end

-- Visualization Helper
function GraphOfThoughts:to_dot()
  local dot = { "digraph GraphOfThoughts {", "  rankdir=TB;" }

  -- Add nodes
  for node_id, node in pairs(self.nodes) do
    local color = "white"
    if node.state == "completed" then
      color = "lightgreen"
    elseif node.state == "processing" then
      color = "yellow"
    elseif node.state == "failed" then
      color = "lightcoral"
    end

    local label =
      string.format("%s\\n%.2f", node.content:sub(1, 20) .. (node.content:len() > 20 and "..." or ""), node.score)

    table.insert(dot, string.format('  "%s" [label="%s", fillcolor="%s", style=filled];', node_id, label, color))
  end

  -- Add edges
  for source_id, targets in pairs(self.edges) do
    for target_id, edge in pairs(targets) do
      table.insert(dot, string.format('  "%s" -> "%s" [label="%.2f"];', source_id, target_id, edge.weight))
    end
  end

  table.insert(dot, "}")
  return table.concat(dot, "\n")
end

-- Node Merging System
function GraphOfThoughts:merge_nodes(source_node_ids, merged_content, merged_id)
  -- Validate all source nodes exist
  for _, node_id in ipairs(source_node_ids) do
    if not self.nodes[node_id] then
      return false, fmt("Source node '%s' does not exist", node_id)
    end
  end

  -- Create the merged node
  local merged_node = ThoughtNode.new(merged_content, merged_id)
  merged_node.metadata.merged_from = source_node_ids
  merged_node.metadata.merge_type = "synthesis"

  -- Calculate merged score based on source nodes
  local total_score = 0
  local total_confidence = 0
  for _, node_id in ipairs(source_node_ids) do
    local source_node = self.nodes[node_id]
    total_score = total_score + source_node.score
    total_confidence = total_confidence + source_node.confidence
  end

  merged_node:set_score(total_score / #source_node_ids, total_confidence / #source_node_ids)

  -- Add merged node to graph
  self.nodes[merged_node.id] = merged_node
  self.edges[merged_node.id] = {}
  self.reverse_edges[merged_node.id] = {}

  -- Create edges from all source nodes to the merged node
  for _, source_id in ipairs(source_node_ids) do
    self:add_edge(source_id, merged_node.id, 1.0, "contributes_to")
  end

  return true, merged_node.id
end

return {
  ThoughtNode = ThoughtNode,
  Edge = Edge,
  GraphOfThoughts = GraphOfThoughts,
}
