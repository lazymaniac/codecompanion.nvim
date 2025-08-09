--=============================================================================
-- Reasoning Visualizer - ASCII visualization for reasoning structures
--=============================================================================

local fmt = string.format

---@class CodeCompanion.ReasoningVisualizer
local ReasoningVisualizer = {}

---@class VisualizationConfig
---@field show_scores boolean Show node scores
---@field show_timestamps boolean Show creation/update times
---@field show_metadata boolean Show additional metadata
---@field max_content_length number Maximum content length per node
---@field indent_size number Spaces for indentation
---@field use_unicode boolean Use Unicode box-drawing characters

local DEFAULT_CONFIG = {
  show_scores = true,
  show_timestamps = false,
  show_metadata = false,
  max_content_length = 60,
  indent_size = 2,
  use_unicode = true,
}

-- Box drawing characters
local BOX_CHARS = {
  unicode = {
    horizontal = "─",
    vertical = "│",
    corner = "┌",
    tee = "├",
    end_tee = "└",
    cross = "┼",
    down_right = "┌",
    down_left = "┐",
    up_right = "└",
    up_left = "┘",
    down_horizontal = "┬",
    up_horizontal = "┴",
    vertical_right = "├",
    vertical_left = "┤",
  },
  ascii = {
    horizontal = "-",
    vertical = "|",
    corner = "+",
    tee = "+",
    end_tee = "+",
    cross = "+",
    down_right = "+",
    down_left = "+",
    up_right = "+",
    up_left = "+",
    down_horizontal = "+",
    up_horizontal = "+",
    vertical_right = "+",
    vertical_left = "+",
  },
}

---Truncate content to specified length
---@param content string
---@param max_length number
---@return string
local function truncate_content(content, max_length)
  if not content then
    return ""
  end
  content = content:gsub("\n", " "):gsub("%s+", " ")
  if #content <= max_length then
    return content
  end
  return content:sub(1, max_length - 3) .. "..."
end

---Format node metadata
---@param node table
---@param config VisualizationConfig
---@return string
local function format_node_info(node, config)
  local parts = {}

  -- Add score if enabled
  if config.show_scores and node.score then
    table.insert(parts, fmt("Score: %.2f", node.score))
  end

  -- Add confidence if available
  if config.show_scores and node.confidence then
    table.insert(parts, fmt("Conf: %.2f", node.confidence))
  end

  -- Add state if available
  if node.state then
    table.insert(parts, fmt("State: %s", node.state))
  end

  -- Add timestamps if enabled
  if config.show_timestamps then
    if node.created_at then
      table.insert(parts, fmt("Created: %s", os.date("%H:%M", node.created_at)))
    end
    if node.updated_at and node.updated_at ~= node.created_at then
      table.insert(parts, fmt("Updated: %s", os.date("%H:%M", node.updated_at)))
    end
  end

  return #parts > 0 and fmt(" (%s)", table.concat(parts, ", ")) or ""
end

---Visualize Chain of Thoughts
---@param chain table Chain of Thoughts instance
---@param config? VisualizationConfig
---@return string
function ReasoningVisualizer.visualize_chain(chain, config)
  config = vim.tbl_extend("force", DEFAULT_CONFIG, config or {})
  local chars = config.use_unicode and BOX_CHARS.unicode or BOX_CHARS.ascii
  local lines = {}

  table.insert(lines, fmt("# Chain of Thoughts: %s", chain.problem or "Unknown"))
  table.insert(lines, "")

  if not chain.steps or #chain.steps == 0 then
    table.insert(lines, "No steps in chain")
    return table.concat(lines, "\n")
  end

  for i, step in ipairs(chain.steps) do
    local is_last = i == #chain.steps
    local connector = is_last and chars.up_right or chars.vertical_right
    local line_char = is_last and " " or chars.vertical

    -- Step header
    local content = truncate_content(step.content, config.max_content_length)
    local step_info = ""
    if config.show_metadata and step.step_type then
      step_info = fmt(" [%s]", step.step_type)
    end

    table.insert(lines, fmt("%s%s Step %d: %s%s", connector, chars.horizontal, i, content, step_info))

    -- Step reasoning (indented)
    if step.reasoning then
      local reasoning = truncate_content(step.reasoning, config.max_content_length - 10)
      table.insert(lines, fmt("%s    Reasoning: %s", line_char, reasoning))
    end

    if i < #chain.steps then
      table.insert(lines, fmt("%s", chars.vertical))
    end
  end

  -- Add conclusion if available
  if chain.conclusion then
    table.insert(lines, "")
    table.insert(
      lines,
      fmt(
        "%s%s Conclusion: %s",
        chars.corner,
        chars.horizontal,
        truncate_content(chain.conclusion, config.max_content_length)
      )
    )
  end

  return table.concat(lines, "\n")
end

---Visualize Tree of Thoughts
---@param root_node table Tree root node
---@param config? VisualizationConfig
---@return string
function ReasoningVisualizer.visualize_tree(root_node, config)
  config = vim.tbl_extend("force", DEFAULT_CONFIG, config or {})
  local chars = config.use_unicode and BOX_CHARS.unicode or BOX_CHARS.ascii
  local lines = {}

  table.insert(lines, "# Tree of Thoughts")
  table.insert(lines, "")

  ---Recursively build tree visualization
  ---@param node table
  ---@param prefix string
  ---@param is_last boolean
  local function build_tree_lines(node, prefix, is_last)
    local content = truncate_content(node.content, config.max_content_length)
    local node_info = format_node_info(node, config)

    local connector = is_last and chars.up_right or chars.vertical_right
    table.insert(lines, fmt("%s%s%s %s%s", prefix, connector, chars.horizontal, content, node_info))

    if node.children and #node.children > 0 then
      local new_prefix = prefix .. (is_last and "  " or (chars.vertical .. " "))

      for i, child in ipairs(node.children) do
        build_tree_lines(child, new_prefix, i == #node.children)
      end
    end
  end

  -- Start with root node
  local content = truncate_content(root_node.content, config.max_content_length)
  local node_info = format_node_info(root_node, config)
  table.insert(lines, fmt("Root: %s%s", content, node_info))

  if root_node.children and #root_node.children > 0 then
    for i, child in ipairs(root_node.children) do
      build_tree_lines(child, "", i == #root_node.children)
    end
  end

  return table.concat(lines, "\n")
end

---Visualize Graph of Thoughts
---@param graph table Graph of Thoughts instance
---@param config? VisualizationConfig
---@return string
function ReasoningVisualizer.visualize_graph(graph, config)
  config = vim.tbl_extend("force", DEFAULT_CONFIG, config or {})
  local chars = config.use_unicode and BOX_CHARS.unicode or BOX_CHARS.ascii
  local lines = {}

  table.insert(lines, "# Graph of Thoughts")
  table.insert(lines, "")

  if not graph.nodes or vim.tbl_count(graph.nodes) == 0 then
    table.insert(lines, "No nodes in graph")
    return table.concat(lines, "\n")
  end

  -- Build node list sorted by creation time or dependency order
  local sorted_nodes = {}
  for id, node in pairs(graph.nodes) do
    table.insert(sorted_nodes, { id = id, node = node })
  end
  table.sort(sorted_nodes, function(a, b)
    return (a.node.created_at or 0) < (b.node.created_at or 0)
  end)

  table.insert(lines, "## Nodes:")
  for _, entry in ipairs(sorted_nodes) do
    local node = entry.node
    local content = truncate_content(node.content, config.max_content_length)
    local node_info = format_node_info(node, config)

    table.insert(lines, fmt("  %s [%s]: %s%s", chars.corner, entry.id, content, node_info))
  end

  -- Show dependencies
  table.insert(lines, "")
  table.insert(lines, "## Dependencies:")

  local has_dependencies = false
  for source_id, targets in pairs(graph.edges or {}) do
    if vim.tbl_count(targets) > 0 then
      has_dependencies = true
      local source_content = graph.nodes[source_id] and truncate_content(graph.nodes[source_id].content, 20)
        or source_id

      for target_id, edge in pairs(targets) do
        local target_content = graph.nodes[target_id] and truncate_content(graph.nodes[target_id].content, 20)
          or target_id

        local weight_info = edge.weight and edge.weight ~= 1.0 and fmt(" (weight: %.2f)", edge.weight) or ""

        table.insert(lines, fmt("  %s → %s%s", source_content, target_content, weight_info))
      end
    end
  end

  if not has_dependencies then
    table.insert(lines, "  No dependencies defined")
  end

  return table.concat(lines, "\n")
end

---Auto-detect reasoning type and visualize accordingly
---@param reasoning_data table
---@param config? VisualizationConfig
---@return string
function ReasoningVisualizer.auto_visualize(reasoning_data, config)
  -- Try to detect the type of reasoning structure
  if reasoning_data.steps then
    -- Chain of Thoughts
    return ReasoningVisualizer.visualize_chain(reasoning_data, config)
  elseif reasoning_data.children or (reasoning_data.content and reasoning_data.depth) then
    -- Tree of Thoughts (single node with children or node with depth)
    return ReasoningVisualizer.visualize_tree(reasoning_data, config)
  elseif reasoning_data.nodes and reasoning_data.edges then
    -- Graph of Thoughts
    return ReasoningVisualizer.visualize_graph(reasoning_data, config)
  else
    return "Unknown reasoning structure format"
  end
end

---Create a summary view of reasoning progress
---@param reasoning_data table
---@return string
function ReasoningVisualizer.create_summary(reasoning_data)
  local lines = {}

  if reasoning_data.steps then
    -- Chain of Thoughts summary
    local completed = 0
    for _, step in ipairs(reasoning_data.steps) do
      if step.completed then
        completed = completed + 1
      end
    end
    table.insert(lines, fmt("Chain Progress: %d/%d steps completed", completed, #reasoning_data.steps))
  elseif reasoning_data.nodes then
    -- Graph of Thoughts summary
    local completed = vim.tbl_count(reasoning_data.completed_nodes or {})
    local failed = vim.tbl_count(reasoning_data.failed_nodes or {})
    local total = vim.tbl_count(reasoning_data.nodes)
    table.insert(lines, fmt("Graph Progress: %d completed, %d failed, %d total nodes", completed, failed, total))
  elseif reasoning_data.children then
    -- Tree of Thoughts summary
    local function count_nodes(node)
      local count = 1
      if node.children then
        for _, child in ipairs(node.children) do
          count = count + count_nodes(child)
        end
      end
      return count
    end

    local total = count_nodes(reasoning_data)
    table.insert(lines, fmt("Tree Structure: %d total nodes", total))
  end

  return table.concat(lines, "\n")
end

return ReasoningVisualizer
