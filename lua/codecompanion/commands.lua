---@class CodeCompanion.Command
---@field cmd string
---@field callback fun(args:table)
---@field opts CodeCompanion.Command.Opts

---@class CodeCompanion.Command.Opts:table
---@field desc string

local codecompanion = require("codecompanion")
local config = require("codecompanion.config")

-- Create the short name prompt library items table
local prompts = vim.iter(config.prompt_library):fold({}, function(acc, key, value)
  if value.opts and value.opts.short_name then
    acc[value.opts.short_name] = value
  end
  return acc
end)

local adapters = vim
  .iter(config.adapters)
  :filter(function(k, _)
    return k ~= "non_llm" and k ~= "opts"
  end)
  :map(function(k, _)
    return k
  end)
  :totable()

local inline_subcommands = vim.deepcopy(adapters)
vim.iter(prompts):each(function(k, _)
  table.insert(inline_subcommands, "/" .. k)
end)

local chat_subcommands = vim.deepcopy(adapters)
table.insert(chat_subcommands, "Toggle")
table.insert(chat_subcommands, "Add")
table.insert(chat_subcommands, "RefreshCache")

---@type CodeCompanion.Command[]
return {
  {
    cmd = "CodeCompanion",
    callback = function(opts)
      -- Detect the user calling a prompt from the prompt library
      if opts.fargs[1] and string.sub(opts.fargs[1], 1, 1) == "/" then
        -- Get the prompt minus the slash
        local prompt = string.sub(opts.fargs[1], 2)

        if prompts[prompt] then
          if #opts.fargs > 1 then
            opts.user_prompt = table.concat(opts.fargs, " ", 2)
          end
          return codecompanion.prompt_library(prompts[prompt], opts)
        end
      end

      -- If the user calls the command with no prompt, then ask for their input
      if #vim.trim(opts.args or "") == 0 then
        vim.ui.input({ prompt = config.display.action_palette.prompt }, function(input)
          if #vim.trim(input or "") == 0 then
            return
          end
          opts.args = input
          return codecompanion.inline(opts)
        end)
      else
        codecompanion.inline(opts)
      end
    end,
    opts = {
      desc = "Use the CodeCompanion Inline Assistant",
      range = true,
      nargs = "*",
      -- Reference:
      -- https://github.com/nvim-neorocks/nvim-best-practices?tab=readme-ov-file#speaking_head-user-commands
      complete = function(arg_lead, cmdline, _)
        if cmdline:match("^['<,'>]*CodeCompanion[!]*%s+/?%w*$") then
          return vim
            .iter(inline_subcommands)
            :filter(function(key)
              return key:find(arg_lead) ~= nil
            end)
            :map(function(key)
              -- Remove the leading "/" if it has already been typed.
              -- This allows matching on /<prompt library> without placing "//".
              if arg_lead:sub(1, 1) == "/" and key:sub(1, 1) == "/" then
                return key:sub(2)
              end
              return key
            end)
            :totable()
        end
      end,
    },
  },
  {
    cmd = "CodeCompanionChat",
    callback = function(opts)
      codecompanion.chat(opts)
    end,
    opts = {
      desc = "Work with a CodeCompanion chat buffer",
      range = true,
      nargs = "*",
      -- Reference:
      -- https://github.com/nvim-neorocks/nvim-best-practices?tab=readme-ov-file#speaking_head-user-commands
      complete = function(arg_lead, cmdline, _)
        if cmdline:match("^['<,'>]*CodeCompanionChat[!]*%s+%w*$") then
          return vim
            .iter(chat_subcommands)
            :filter(function(key)
              return key:find(arg_lead) ~= nil
            end)
            :totable()
        end
      end,
    },
  },
  {
    cmd = "CodeCompanionCmd",
    callback = function(opts)
      codecompanion.cmd(opts)
    end,
    opts = {
      desc = "Prompt the LLM to write a command for the command-line",
      range = false,
      nargs = "*",
    },
  },

  {
    cmd = "CodeCompanionActions",
    callback = function(opts)
      codecompanion.actions(opts)
    end,
    opts = {
      desc = "Open the CodeCompanion actions palette",
      range = true,
    },
  },
  {
    cmd = "CodeCompanionMemoryCleanup",
    callback = function(opts)
      local MemoryManager = require("codecompanion.strategies.chat.memory_manager")
      local util = require("codecompanion.utils")

      local max_age_days = tonumber((opts.fargs and opts.fargs[1]) or "30")
      local dry_run = opts.bang == false -- Use ! to disable dry run

      vim.ui.select({ "30 days", "60 days", "90 days", "Custom..." }, {
        prompt = "Remove memory files older than:",
        format_item = function(item)
          return item
        end,
      }, function(selected)
        if not selected then
          return
        end

        if selected == "Custom..." then
          vim.ui.input({
            prompt = "Enter max age in days: ",
            default = tostring(max_age_days),
          }, function(input)
            if not input or input == "" then
              return
            end
            max_age_days = tonumber(input) or max_age_days

            local results = MemoryManager.cleanup_memory_files({
              max_age_days = max_age_days,
              remove_invalid = true,
              dry_run = dry_run,
            })

            local message = string.format(
              "%s: Processed %d files, would remove %d old + %d invalid files",
              dry_run and "DRY RUN" or "CLEANUP",
              results.processed,
              results.removed_old,
              results.removed_invalid
            )

            if results.errors > 0 then
              message = message .. string.format(" (%d errors)", results.errors)
            end

            util.notify(message, vim.log.levels.INFO)
          end)
        else
          max_age_days = tonumber(selected:match("(%d+)")) or max_age_days

          local results = MemoryManager.cleanup_memory_files({
            max_age_days = max_age_days,
            remove_invalid = true,
            dry_run = dry_run,
          })

          local message = string.format(
            "%s: Processed %d files, %s %d old + %d invalid files",
            dry_run and "DRY RUN" or "CLEANUP",
            results.processed,
            dry_run and "would remove" or "removed",
            results.removed_old,
            results.removed_invalid
          )

          if results.errors > 0 then
            message = message .. string.format(" (%d errors)", results.errors)
          end

          util.notify(message, vim.log.levels.INFO)
        end
      end)
    end,
    opts = {
      desc = "Clean up old memory files (use ! to actually delete, default is dry run)",
      bang = true,
      nargs = "?",
    },
  },
  {
    cmd = "CodeCompanionMemoryList",
    callback = function(opts)
      local MemoryManager = require("codecompanion.strategies.chat.memory_manager")
      local util = require("codecompanion.utils")

      local include_invalid = vim.tbl_contains(opts.fargs or {}, "invalid")
      local sort_by = "modified" -- Default sort

      -- Parse sort option from args
      for _, arg in ipairs(opts.fargs or {}) do
        if vim.tbl_contains({ "modified", "size", "entries", "memory_id" }, arg) then
          sort_by = arg
          break
        end
      end

      local files = MemoryManager.list_memory_files({
        include_invalid = include_invalid,
        sort_by = sort_by,
        reverse = true, -- Most recent first
      })

      if #files == 0 then
        return util.notify("No memory files found", vim.log.levels.INFO)
      end

      local info_lines = {
        "# Memory Files",
        string.format("Found %d memory files (sorted by %s):", #files, sort_by),
        "",
      }

      for i, file in ipairs(files) do
        if i > 20 then -- Limit display
          table.insert(info_lines, string.format("... and %d more files", #files - 20))
          break
        end

        local status = file.valid and "✓" or "✗"
        local size_kb = string.format("%.1f KB", file.size / 1024)
        local date = os.date("%Y-%m-%d %H:%M", file.modified)
        local entries = file.entry_count or 0

        table.insert(
          info_lines,
          string.format(
            "%s **%s** (%s, %d entries, %s) - %s",
            status,
            file.memory_id,
            size_kb,
            entries,
            date,
            file.adapter_name or "unknown"
          )
        )
      end

      table.insert(info_lines, "")
      table.insert(info_lines, "Use `:CodeCompanionMemoryCleanup` to clean old files")

      local info_text = table.concat(info_lines, "\n")
      util.notify(info_text, vim.log.levels.INFO)
    end,
    opts = {
      desc = "List all memory files (options: invalid, modified, size, entries, memory_id)",
      nargs = "*",
      complete = function(arg_lead, cmdline, _)
        local options = { "invalid", "modified", "size", "entries", "memory_id" }
        return vim.tbl_filter(function(opt)
          return opt:find(arg_lead) ~= nil
        end, options)
      end,
    },
  },
  {
    cmd = "CodeCompanionBranches",
    callback = function(opts)
      local chat = codecompanion.last_chat()

      if not chat then
        return vim.notify("No active chat found", vim.log.levels.WARN)
      end

      if not chat.branch_ui then
        return vim.notify("Conversation branching not available", vim.log.levels.WARN)
      end

      local action = opts.fargs and opts.fargs[1] or nil

      if action == "tree" then
        chat.branch_ui:show_branch_tree()
      elseif action == "create" then
        chat.branch_ui:create_branch_interactive()
      elseif action == "switch" then
        chat.branch_ui:switch_branch_interactive()
      elseif action == "merge" then
        chat.branch_ui:merge_branch_interactive()
      elseif action == "stats" then
        chat.branch_ui:show_branch_stats()
      else
        chat.branch_ui:show_branch_management()
      end
    end,
    opts = {
      desc = "Manage conversation branches (tree, create, switch, merge, stats)",
      nargs = "?",
      complete = function(arg_lead, cmdline, _)
        local actions = { "tree", "create", "switch", "merge", "stats" }
        return vim.tbl_filter(function(action)
          return action:find(arg_lead) ~= nil
        end, actions)
      end,
    },
  },
}
