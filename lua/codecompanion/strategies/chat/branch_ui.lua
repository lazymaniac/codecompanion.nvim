--=============================================================================
-- Branch UI - Handles branch visualization and user interactions
--=============================================================================

local log = require("codecompanion.utils.log")
local ui = require("codecompanion.utils.ui")
local util = require("codecompanion.utils")

local api = vim.api
local fmt = string.format

---@class CodeCompanion.Chat.BranchUI
---@field chat CodeCompanion.Chat Reference to the chat instance
---@field branch_manager CodeCompanion.Chat.BranchManager Reference to branch manager
local BranchUI = {}
BranchUI.__index = BranchUI

---Create a new BranchUI instance
---@param chat CodeCompanion.Chat
---@param branch_manager CodeCompanion.Chat.BranchManager
---@return CodeCompanion.Chat.BranchUI
function BranchUI.new(chat, branch_manager)
  local self = setmetatable({
    chat = chat,
    branch_manager = branch_manager,
  }, BranchUI)

  log:debug("[BranchUI] Initialized for chat %d", chat.id)
  return self
end

---Show branch tree visualization
function BranchUI:show_branch_tree()
  if not self.branch_manager:can_branch() then
    return util.notify("Branching not available", vim.log.levels.WARN)
  end

  local tree = self.branch_manager:get_branch_tree()
  if not tree then
    return util.notify("No branch tree available", vim.log.levels.ERROR)
  end

  local lines = { "# Branch Tree", "" }
  local branch_list = {} -- Keep track for selection

  local function render_tree_node(node, prefix, is_last)
    local branch_indicator = node.is_current and "●" or "○"
    local connector = is_last and "└── " or "├── "
    local name = node.is_current and fmt("**%s**", node.name) or node.name
    local info = fmt("(%d messages)", node.message_count)

    table.insert(lines, fmt("%s%s%s %s %s", prefix, connector, branch_indicator, name, info))
    table.insert(branch_list, node.id)

    -- Render children
    for i, child in ipairs(node.children) do
      local child_prefix = prefix .. (is_last and "    " or "│   ")
      local child_is_last = i == #node.children
      render_tree_node(child, child_prefix, child_is_last)
    end
  end

  render_tree_node(tree, "", true)

  table.insert(lines, "")
  table.insert(lines, "**Legend:** ● Current branch, ○ Other branches")
  table.insert(lines, "Press number key to switch branches, 'q' to close")

  local float_opts = {
    title = "🌲 Branch Tree",
    lock = false,
    window = {
      border = "rounded",
      width = 60,
      height = math.min(#lines + 2, 20),
    },
  }

  local bufnr, winnr = ui.create_float(lines, float_opts)

  -- Set up keymaps
  local function close_float()
    if winnr and api.nvim_win_is_valid(winnr) then
      api.nvim_win_close(winnr, true)
    end
  end

  -- Close with 'q'
  api.nvim_buf_set_keymap(bufnr, "n", "q", "", {
    noremap = true,
    silent = true,
    callback = close_float,
  })

  -- Number keys to switch branches
  for i = 1, math.min(#branch_list, 9) do
    api.nvim_buf_set_keymap(bufnr, "n", tostring(i), "", {
      noremap = true,
      silent = true,
      callback = function()
        self.branch_manager:switch_to_branch(branch_list[i])
        close_float()
      end,
    })
  end
end

---Show branch management interface
function BranchUI:show_branch_management()
  if not self.branch_manager:can_branch() then
    return util.notify("Branching not available", vim.log.levels.WARN)
  end

  local actions = {
    "Create new branch",
    "Switch branch",
    "Merge branch",
    "Rename branch",
    "Delete branch",
    "Show branch tree",
    "Branch statistics",
  }

  vim.ui.select(actions, {
    prompt = "Branch Management:",
    format_item = function(item)
      return item
    end,
  }, function(selected, idx)
    if not selected then
      return
    end

    if idx == 1 then
      self:create_branch_interactive()
    elseif idx == 2 then
      self:switch_branch_interactive()
    elseif idx == 3 then
      self:merge_branch_interactive()
    elseif idx == 4 then
      self:rename_branch_interactive()
    elseif idx == 5 then
      self:delete_branch_interactive()
    elseif idx == 6 then
      self:show_branch_tree()
    elseif idx == 7 then
      self:show_branch_stats()
    end
  end)
end

---Interactive branch creation
function BranchUI:create_branch_interactive()
  vim.ui.input({
    prompt = "Branch name: ",
    default = fmt("Branch %d", self.branch_manager.branch_counter + 1),
  }, function(name)
    if not name or name == "" then
      return
    end

    vim.ui.input({
      prompt = "Description (optional): ",
    }, function(description)
      local branch_id = self.branch_manager:create_branch(name, description)
      if branch_id then
        util.notify(fmt("Created and switched to branch '%s'", name), vim.log.levels.INFO)
      else
        util.notify("Failed to create branch", vim.log.levels.ERROR)
      end
    end)
  end)
end

---Interactive branch switching
function BranchUI:switch_branch_interactive()
  local branches = self.branch_manager:get_all_branches()
  local current_id = self.branch_manager.current_branch_id

  local branch_options = {}
  local branch_ids = {}

  for id, branch in pairs(branches) do
    if id ~= current_id then
      local info = fmt("%s (%d messages)", branch.name, #branch.messages)
      table.insert(branch_options, info)
      table.insert(branch_ids, id)
    end
  end

  if #branch_options == 0 then
    return util.notify("No other branches available", vim.log.levels.INFO)
  end

  vim.ui.select(branch_options, {
    prompt = "Switch to branch:",
    format_item = function(item)
      return item
    end,
  }, function(selected, idx)
    if not selected then
      return
    end

    local branch_id = branch_ids[idx]
    if self.branch_manager:switch_to_branch(branch_id) then
      local branch = self.branch_manager:get_branch(branch_id)
      util.notify(fmt("Switched to branch '%s'", branch.name), vim.log.levels.INFO)
    else
      util.notify("Failed to switch branch", vim.log.levels.ERROR)
    end
  end)
end

---Interactive branch merging
function BranchUI:merge_branch_interactive()
  local branches = self.branch_manager:get_all_branches()
  local current_id = self.branch_manager.current_branch_id

  local branch_options = {}
  local branch_ids = {}

  for id, branch in pairs(branches) do
    if id ~= current_id then
      local info = fmt("%s (%d messages)", branch.name, #branch.messages)
      table.insert(branch_options, info)
      table.insert(branch_ids, id)
    end
  end

  if #branch_options == 0 then
    return util.notify("No other branches available to merge", vim.log.levels.INFO)
  end

  vim.ui.select(branch_options, {
    prompt = "Merge from branch:",
    format_item = function(item)
      return item
    end,
  }, function(selected, idx)
    if not selected then
      return
    end

    local source_branch_id = branch_ids[idx]
    local preview = self.branch_manager:get_merge_preview(source_branch_id)

    if not preview then
      return util.notify("Cannot generate merge preview", vim.log.levels.ERROR)
    end

    -- Show merge preview
    local preview_text = fmt(
      "Merge Preview:\n\nFrom: %s\nTo: %s\n\nWill add %d messages\nTotal after merge: %d messages",
      preview.source_branch.name,
      preview.target_branch.name,
      preview.new_message_count,
      preview.total_after_merge
    )

    local confirm = vim.fn.confirm(preview_text .. "\n\nProceed with merge?", "&Yes\n&No", 2)

    if confirm == 1 then
      -- Choose merge strategy
      local strategies = { "append", "replace" }
      vim.ui.select(strategies, {
        prompt = "Merge strategy:",
        format_item = function(item)
          if item == "append" then
            return "Append - Add new messages to current branch"
          elseif item == "replace" then
            return "Replace - Replace current branch with source"
          end
          return item
        end,
      }, function(strategy)
        if not strategy then
          return
        end

        if self.branch_manager:merge_branch(source_branch_id, strategy) then
          util.notify(
            fmt("Merged branch '%s' using strategy '%s'", preview.source_branch.name, strategy),
            vim.log.levels.INFO
          )
        else
          util.notify("Failed to merge branch", vim.log.levels.ERROR)
        end
      end)
    end
  end)
end

---Interactive branch renaming
function BranchUI:rename_branch_interactive()
  local branches = self.branch_manager:get_all_branches()
  local branch_options = {}
  local branch_ids = {}

  for id, branch in pairs(branches) do
    table.insert(branch_options, fmt("%s (%s)", branch.name, id))
    table.insert(branch_ids, id)
  end

  vim.ui.select(branch_options, {
    prompt = "Rename branch:",
    format_item = function(item)
      return item
    end,
  }, function(selected, idx)
    if not selected then
      return
    end

    local branch_id = branch_ids[idx]
    local branch = self.branch_manager:get_branch(branch_id)

    vim.ui.input({
      prompt = "New name: ",
      default = branch.name,
    }, function(new_name)
      if not new_name or new_name == "" then
        return
      end

      if self.branch_manager:rename_branch(branch_id, new_name) then
        util.notify(fmt("Renamed branch to '%s'", new_name), vim.log.levels.INFO)
      else
        util.notify("Failed to rename branch", vim.log.levels.ERROR)
      end
    end)
  end)
end

---Interactive branch deletion
function BranchUI:delete_branch_interactive()
  local branches = self.branch_manager:get_all_branches()
  local current_id = self.branch_manager.current_branch_id

  local branch_options = {}
  local branch_ids = {}

  for id, branch in pairs(branches) do
    if id ~= current_id and id ~= "main" then -- Can't delete current or main
      local info = fmt("%s (%d messages)", branch.name, #branch.messages)
      table.insert(branch_options, info)
      table.insert(branch_ids, id)
    end
  end

  if #branch_options == 0 then
    return util.notify("No branches available for deletion", vim.log.levels.INFO)
  end

  vim.ui.select(branch_options, {
    prompt = "Delete branch (WARNING: This cannot be undone):",
    format_item = function(item)
      return "🗑️ " .. item
    end,
  }, function(selected, idx)
    if not selected then
      return
    end

    local branch_id = branch_ids[idx]
    local branch = self.branch_manager:get_branch(branch_id)

    local confirm = vim.fn.confirm(
      fmt(
        "Delete branch '%s'?\n\nThis will also delete all child branches!\n\nThis action cannot be undone.",
        branch.name
      ),
      "&Delete\n&Cancel",
      2
    )

    if confirm == 1 then
      if self.branch_manager:delete_branch(branch_id) then
        util.notify(fmt("Deleted branch '%s'", branch.name), vim.log.levels.INFO)
      else
        util.notify("Failed to delete branch", vim.log.levels.ERROR)
      end
    end
  end)
end

---Show branch statistics
function BranchUI:show_branch_stats()
  local stats = self.branch_manager:get_stats()

  local info_lines = {
    "# Branch Statistics",
    "",
    fmt("**Total Branches:** %d", stats.total_branches),
    fmt("**Active Branches:** %d", stats.active_branches),
    fmt("**Current Branch:** %s (%s)", stats.current_branch.name, stats.current_branch.id),
    "",
  }

  if stats.oldest_branch_date then
    table.insert(info_lines, fmt("**Oldest Branch:** %s", os.date("%Y-%m-%d %H:%M", stats.oldest_branch_date)))
  end
  if stats.newest_branch_date then
    table.insert(info_lines, fmt("**Newest Branch:** %s", os.date("%Y-%m-%d %H:%M", stats.newest_branch_date)))
  end

  table.insert(info_lines, "")
  table.insert(info_lines, "## Branch List:")

  local branches = self.branch_manager:get_all_branches()
  local sorted_branches = {}

  for id, branch in pairs(branches) do
    table.insert(sorted_branches, { id = id, branch = branch })
  end

  table.sort(sorted_branches, function(a, b)
    return a.branch.created_at > b.branch.created_at
  end)

  for _, item in ipairs(sorted_branches) do
    local branch = item.branch
    local indicator = branch.id == self.branch_manager.current_branch_id and "●" or "○"
    local age = os.difftime(os.time(), branch.created_at)
    local age_str = age < 3600 and fmt("%.0fm ago", age / 60)
      or age < 86400 and fmt("%.0fh ago", age / 3600)
      or fmt("%.0fd ago", age / 86400)

    table.insert(info_lines, fmt("%s **%s** - %d messages (%s)", indicator, branch.name, #branch.messages, age_str))
  end

  local info_text = table.concat(info_lines, "\n")
  util.notify(info_text, vim.log.levels.INFO)
end

---Show current branch indicator in chat UI
---@return string Branch indicator text
function BranchUI:get_branch_indicator()
  local current_branch = self.branch_manager:get_current_branch()
  if not current_branch or current_branch.id == "main" then
    return ""
  end

  local path = self.branch_manager:get_branch_path()
  if #path <= 1 then
    return fmt("📋 %s", current_branch.name)
  else
    -- Show path if nested
    local path_names = {}
    for _, branch_id in ipairs(path) do
      if branch_id ~= "main" then -- Skip main in path display
        local branch = self.branch_manager:get_branch(branch_id)
        table.insert(path_names, branch and branch.name or branch_id)
      end
    end
    return fmt("📋 %s", table.concat(path_names, " → "))
  end
end

---Update chat UI to show branch information
function BranchUI:update_chat_ui()
  local indicator = self:get_branch_indicator()
  if indicator ~= "" and self.chat.ui then
    -- This would be integrated with the chat UI to show branch indicator
    -- For now, we'll just log it
    log:debug("[BranchUI] Branch indicator: %s", indicator)
  end
end

return BranchUI
