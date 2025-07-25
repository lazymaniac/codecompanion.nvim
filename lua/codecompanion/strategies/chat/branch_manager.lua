--=============================================================================
-- Branch Manager - Handles conversation branching, switching, and merging
--=============================================================================

local log = require("codecompanion.utils.log")
local util = require("codecompanion.utils")

local fmt = string.format

---@class CodeCompanion.Chat.BranchManager
---@field chat CodeCompanion.Chat Reference to the chat instance
---@field branches table Tree structure of conversation branches
---@field current_branch_id string ID of the currently active branch
---@field branch_counter number Counter for generating unique branch IDs
---@field enabled boolean Whether branching is enabled
local BranchManager = {}
BranchManager.__index = BranchManager

---@class CodeCompanion.Chat.Branch
---@field id string Unique identifier for the branch
---@field name string User-friendly name for the branch
---@field parent_id string|nil ID of the parent branch
---@field branch_point_cycle number The cycle number where this branch diverged
---@field messages table Messages specific to this branch (from branch point onward)
---@field children table Array of child branch IDs
---@field created_at number Timestamp when branch was created
---@field last_active number Timestamp when branch was last active
---@field metadata table Additional branch information

---Create a new BranchManager instance
---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.BranchManager
function BranchManager.new(chat)
  local self = setmetatable({
    chat = chat,
    branches = {},
    current_branch_id = "main",
    branch_counter = 0,
    enabled = true,
  }, BranchManager)

  -- Initialize main branch
  self:_init_main_branch()

  log:debug("[BranchManager] Initialized for chat %d", chat.id)
  return self
end

---Initialize the main branch
function BranchManager:_init_main_branch()
  local main_branch = {
    id = "main",
    name = "Main",
    parent_id = nil,
    branch_point_cycle = 0,
    messages = vim.deepcopy(self.chat.messages or {}),
    children = {},
    created_at = os.time(),
    last_active = os.time(),
    metadata = {
      is_main = true,
      description = "Main conversation thread",
    },
  }

  self.branches["main"] = main_branch
  self.current_branch_id = "main"
end

---Generate a unique branch ID
---@return string Unique branch ID
function BranchManager:_generate_branch_id()
  self.branch_counter = self.branch_counter + 1
  return fmt("branch_%d", self.branch_counter)
end

---Get the current branch
---@return CodeCompanion.Chat.Branch Current branch object
function BranchManager:get_current_branch()
  return self.branches[self.current_branch_id]
end

---Get a branch by ID
---@param branch_id string The branch ID to retrieve
---@return CodeCompanion.Chat.Branch|nil Branch object or nil if not found
function BranchManager:get_branch(branch_id)
  return self.branches[branch_id]
end

---Get all branches
---@return table Table of all branches keyed by ID
function BranchManager:get_all_branches()
  return vim.deepcopy(self.branches)
end

---Create a new branch from the current position
---@param name? string Optional name for the new branch
---@param description? string Optional description for the new branch
---@return string|nil New branch ID or nil if creation failed
function BranchManager:create_branch(name, description)
  if not self.enabled then
    log:warn("[BranchManager] Branching is disabled")
    return nil
  end

  local current_branch = self:get_current_branch()
  if not current_branch then
    log:error("[BranchManager] Current branch not found")
    return nil
  end

  local new_branch_id = self:_generate_branch_id()
  local current_cycle = self.chat.cycle or 0

  -- Generate name if not provided
  if not name or name == "" then
    name = fmt("Branch %d", self.branch_counter)
  end

  -- Create new branch
  local new_branch = {
    id = new_branch_id,
    name = name,
    parent_id = self.current_branch_id,
    branch_point_cycle = current_cycle,
    messages = vim.deepcopy(self.chat.messages or {}),
    children = {},
    created_at = os.time(),
    last_active = os.time(),
    metadata = {
      description = description or fmt("Branched from %s at cycle %d", current_branch.name, current_cycle),
      branch_point_message_count = #(self.chat.messages or {}),
    },
  }

  -- Add to branches
  self.branches[new_branch_id] = new_branch

  -- Update parent branch children
  table.insert(current_branch.children, new_branch_id)

  -- Switch to new branch
  self:switch_to_branch(new_branch_id)

  log:info(
    "[BranchManager] Created branch '%s' (%s) from %s at cycle %d",
    name,
    new_branch_id,
    current_branch.name,
    current_cycle
  )

  return new_branch_id
end

---Switch to a different branch
---@param branch_id string The branch ID to switch to
---@return boolean Success status
function BranchManager:switch_to_branch(branch_id)
  if not self.enabled then
    log:warn("[BranchManager] Branching is disabled")
    return false
  end

  local target_branch = self.branches[branch_id]
  if not target_branch then
    log:error("[BranchManager] Branch '%s' not found", branch_id)
    return false
  end

  if branch_id == self.current_branch_id then
    log:debug("[BranchManager] Already on branch '%s'", branch_id)
    return true
  end

  -- Save current branch state
  local current_branch = self:get_current_branch()
  if current_branch then
    current_branch.messages = vim.deepcopy(self.chat.messages or {})
    current_branch.last_active = os.time()
  end

  -- Switch to target branch
  self.current_branch_id = branch_id
  target_branch.last_active = os.time()

  -- Update chat messages
  self.chat.messages = vim.deepcopy(target_branch.messages)

  -- Update chat cycle to match branch
  if target_branch.messages and #target_branch.messages > 0 then
    local last_cycle = 0
    for _, message in ipairs(target_branch.messages) do
      if message.cycle and message.cycle > last_cycle then
        last_cycle = message.cycle
      end
    end
    self.chat.cycle = last_cycle
  end

  -- Refresh UI to show new branch content
  if self.chat.ui then
    self.chat.ui:render()
  end

  log:info("[BranchManager] Switched to branch '%s' (%s)", target_branch.name, branch_id)

  -- Notify user
  util.fire("ChatBranchSwitched", {
    chat_id = self.chat.id,
    from_branch = current_branch and current_branch.id or nil,
    to_branch = branch_id,
    branch_name = target_branch.name,
  })

  return true
end

---Delete a branch and all its children
---@param branch_id string The branch ID to delete
---@return boolean Success status
function BranchManager:delete_branch(branch_id)
  if not self.enabled then
    log:warn("[BranchManager] Branching is disabled")
    return false
  end

  -- Can't delete main branch
  if branch_id == "main" then
    log:warn("[BranchManager] Cannot delete main branch")
    return false
  end

  local branch = self.branches[branch_id]
  if not branch then
    log:error("[BranchManager] Branch '%s' not found", branch_id)
    return false
  end

  -- Can't delete current branch
  if branch_id == self.current_branch_id then
    log:warn("[BranchManager] Cannot delete current branch, switch to another branch first")
    return false
  end

  -- Recursively delete children
  local function delete_branch_recursive(bid)
    local b = self.branches[bid]
    if not b then
      return
    end

    -- Delete all children first
    for _, child_id in ipairs(b.children) do
      delete_branch_recursive(child_id)
    end

    -- Remove from parent's children list
    if b.parent_id then
      local parent = self.branches[b.parent_id]
      if parent then
        for i, child_id in ipairs(parent.children) do
          if child_id == bid then
            table.remove(parent.children, i)
            break
          end
        end
      end
    end

    -- Delete the branch
    self.branches[bid] = nil
    log:debug("[BranchManager] Deleted branch '%s' (%s)", b.name, bid)
  end

  delete_branch_recursive(branch_id)

  log:info("[BranchManager] Deleted branch '%s' (%s) and all its children", branch.name, branch_id)
  return true
end

---Rename a branch
---@param branch_id string The branch ID to rename
---@param new_name string The new name for the branch
---@return boolean Success status
function BranchManager:rename_branch(branch_id, new_name)
  if not new_name or new_name == "" then
    return false
  end

  local branch = self.branches[branch_id]
  if not branch then
    log:error("[BranchManager] Branch '%s' not found", branch_id)
    return false
  end

  local old_name = branch.name
  branch.name = new_name

  log:info("[BranchManager] Renamed branch '%s' to '%s' (%s)", old_name, new_name, branch_id)
  return true
end

---Get the path from main to current branch
---@return table Array of branch IDs from main to current
function BranchManager:get_branch_path()
  local path = {}
  local current_id = self.current_branch_id

  while current_id do
    table.insert(path, 1, current_id) -- Insert at beginning
    local branch = self.branches[current_id]
    current_id = branch and branch.parent_id or nil
  end

  return path
end

---Get branch hierarchy as a tree structure
---@return table Tree structure starting from main
function BranchManager:get_branch_tree()
  local function build_tree(branch_id, depth)
    local branch = self.branches[branch_id]
    if not branch then
      return nil
    end

    local tree_node = {
      id = branch_id,
      name = branch.name,
      is_current = branch_id == self.current_branch_id,
      depth = depth or 0,
      created_at = branch.created_at,
      last_active = branch.last_active,
      message_count = #branch.messages,
      metadata = branch.metadata,
      children = {},
    }

    -- Build children
    for _, child_id in ipairs(branch.children) do
      local child_tree = build_tree(child_id, (depth or 0) + 1)
      if child_tree then
        table.insert(tree_node.children, child_tree)
      end
    end

    -- Sort children by creation time
    table.sort(tree_node.children, function(a, b)
      return a.created_at < b.created_at
    end)

    return tree_node
  end

  return build_tree("main", 0)
end

---Get branch statistics
---@return table Statistics about the branch system
function BranchManager:get_stats()
  local total_branches = vim.tbl_count(self.branches)
  local active_branches = 0
  local oldest_branch = math.huge
  local newest_branch = 0

  for _, branch in pairs(self.branches) do
    if branch.last_active > os.time() - 3600 then -- Active in last hour
      active_branches = active_branches + 1
    end
    oldest_branch = math.min(oldest_branch, branch.created_at)
    newest_branch = math.max(newest_branch, branch.created_at)
  end

  local current_branch = self:get_current_branch()

  return {
    enabled = self.enabled,
    total_branches = total_branches,
    active_branches = active_branches,
    current_branch = {
      id = self.current_branch_id,
      name = current_branch and current_branch.name or "Unknown",
    },
    oldest_branch_date = oldest_branch ~= math.huge and oldest_branch or nil,
    newest_branch_date = newest_branch ~= 0 and newest_branch or nil,
  }
end

---Enable or disable branching
---@param enabled boolean
function BranchManager:set_enabled(enabled)
  self.enabled = enabled
  log:debug("[BranchManager] %s", enabled and "Enabled" or "Disabled")
end

---Update current branch with latest messages
function BranchManager:update_current_branch()
  local current_branch = self:get_current_branch()
  if current_branch then
    current_branch.messages = vim.deepcopy(self.chat.messages or {})
    current_branch.last_active = os.time()
  end
end

---Merge messages from another branch into the current branch
---@param source_branch_id string The branch to merge from
---@param merge_strategy? string Strategy for merging ("append", "replace", "interactive")
---@return boolean Success status
function BranchManager:merge_branch(source_branch_id, merge_strategy)
  if not self.enabled then
    log:warn("[BranchManager] Branching is disabled")
    return false
  end

  merge_strategy = merge_strategy or "append"

  local source_branch = self.branches[source_branch_id]
  local current_branch = self:get_current_branch()

  if not source_branch then
    log:error("[BranchManager] Source branch '%s' not found", source_branch_id)
    return false
  end

  if not current_branch then
    log:error("[BranchManager] Current branch not found")
    return false
  end

  if source_branch_id == self.current_branch_id then
    log:warn("[BranchManager] Cannot merge branch into itself")
    return false
  end

  -- Update current branch state before merging
  self:update_current_branch()

  local merged_messages = {}

  if merge_strategy == "replace" then
    -- Replace current messages with source branch messages
    merged_messages = vim.deepcopy(source_branch.messages)
  elseif merge_strategy == "append" then
    -- Append source branch messages to current branch
    merged_messages = vim.deepcopy(current_branch.messages)

    -- Find messages in source that are newer than branch point
    local branch_point_cycle = source_branch.branch_point_cycle
    for _, message in ipairs(source_branch.messages) do
      local message_cycle = message.cycle or 0
      if message_cycle > branch_point_cycle then
        table.insert(merged_messages, vim.deepcopy(message))
      end
    end
  elseif merge_strategy == "interactive" then
    -- This would be handled by the UI layer
    log:debug("[BranchManager] Interactive merge requested for branch '%s'", source_branch_id)
    return false -- Let UI handle interactive merging
  end

  -- Apply merged messages
  current_branch.messages = merged_messages
  self.chat.messages = vim.deepcopy(merged_messages)

  -- Update cycle counter
  local max_cycle = 0
  for _, message in ipairs(merged_messages) do
    if message.cycle and message.cycle > max_cycle then
      max_cycle = message.cycle
    end
  end
  self.chat.cycle = max_cycle

  -- Update branch metadata
  current_branch.last_active = os.time()
  if not current_branch.metadata.merges then
    current_branch.metadata.merges = {}
  end
  table.insert(current_branch.metadata.merges, {
    from_branch_id = source_branch_id,
    from_branch_name = source_branch.name,
    strategy = merge_strategy,
    timestamp = os.time(),
    message_count = #merged_messages,
  })

  -- Refresh UI
  if self.chat.ui then
    self.chat.ui:render()
  end

  log:info(
    "[BranchManager] Merged branch '%s' into '%s' using strategy '%s'",
    source_branch.name,
    current_branch.name,
    merge_strategy
  )

  -- Notify user
  util.fire("ChatBranchMerged", {
    chat_id = self.chat.id,
    source_branch = source_branch_id,
    target_branch = self.current_branch_id,
    strategy = merge_strategy,
  })

  return true
end

---Get merge preview for two branches
---@param source_branch_id string The branch to merge from
---@param target_branch_id? string The branch to merge into (current if nil)
---@return table|nil Merge preview information
function BranchManager:get_merge_preview(source_branch_id, target_branch_id)
  target_branch_id = target_branch_id or self.current_branch_id

  local source_branch = self.branches[source_branch_id]
  local target_branch = self.branches[target_branch_id]

  if not source_branch or not target_branch then
    return nil
  end

  -- Count messages that would be added
  local new_messages = {}
  local branch_point_cycle = source_branch.branch_point_cycle

  for _, message in ipairs(source_branch.messages) do
    local message_cycle = message.cycle or 0
    if message_cycle > branch_point_cycle then
      table.insert(new_messages, {
        role = message.role,
        content = message.content and message.content:sub(1, 100) or "[No content]",
        cycle = message_cycle,
      })
    end
  end

  return {
    source_branch = {
      id = source_branch_id,
      name = source_branch.name,
    },
    target_branch = {
      id = target_branch_id,
      name = target_branch.name,
    },
    new_messages = new_messages,
    new_message_count = #new_messages,
    current_message_count = #target_branch.messages,
    total_after_merge = #target_branch.messages + #new_messages,
  }
end

---Find common ancestor between two branches
---@param branch_id_1 string First branch ID
---@param branch_id_2 string Second branch ID
---@return string|nil Common ancestor branch ID
function BranchManager:find_common_ancestor(branch_id_1, branch_id_2)
  -- Get paths to root for both branches
  local function get_path_to_root(branch_id)
    local path = {}
    local current_id = branch_id

    while current_id do
      table.insert(path, current_id)
      local branch = self.branches[current_id]
      current_id = branch and branch.parent_id or nil
    end

    return path
  end

  local path_1 = get_path_to_root(branch_id_1)
  local path_2 = get_path_to_root(branch_id_2)

  -- Find first common branch in paths
  local path_1_set = {}
  for _, branch_id in ipairs(path_1) do
    path_1_set[branch_id] = true
  end

  for _, branch_id in ipairs(path_2) do
    if path_1_set[branch_id] then
      return branch_id
    end
  end

  return nil
end

---Export branch structure for persistence
---@return table Serializable branch data
function BranchManager:export_branches()
  return {
    branches = vim.deepcopy(self.branches),
    current_branch_id = self.current_branch_id,
    branch_counter = self.branch_counter,
    enabled = self.enabled,
  }
end

---Import branch structure from persistence
---@param branch_data table Previously exported branch data
---@return boolean Success status
function BranchManager:import_branches(branch_data)
  if not branch_data or not branch_data.branches then
    return false
  end

  self.branches = branch_data.branches
  self.current_branch_id = branch_data.current_branch_id or "main"
  self.branch_counter = branch_data.branch_counter or 0
  self.enabled = branch_data.enabled ~= false

  -- Ensure current branch exists
  if not self.branches[self.current_branch_id] then
    self.current_branch_id = "main"
  end

  -- Update chat messages with current branch
  local current_branch = self:get_current_branch()
  if current_branch then
    self.chat.messages = vim.deepcopy(current_branch.messages)
  end

  log:info("[BranchManager] Imported %d branches", vim.tbl_count(self.branches))
  return true
end

---Check if branching is available
---@return boolean Whether branching can be used
function BranchManager:can_branch()
  return self.enabled and self.chat.messages and #self.chat.messages > 0
end

return BranchManager
