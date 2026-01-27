---@class CodeCompanion.Command
---@field cmd string
---@field callback fun(args:table)
---@field opts CodeCompanion.Command.Opts

---@class CodeCompanion.Command.Opts:table
---@field desc string

local codecompanion = require("codecompanion")
local config = require("codecompanion.config")

local _cached_adapters = nil

---Get the available adapters from the config
---@return string[]
local function get_adapters()
  if not _cached_adapters then
    local config_adapters = vim.tbl_deep_extend("force", {}, config.adapters.acp, config.adapters.http)
    _cached_adapters = vim
      .iter(config_adapters)
      :filter(function(k, _)
        return k ~= "acp" and k ~= "http" and k ~= "opts"
      end)
      :map(function(k, _)
        return k
      end)
      :totable()
  end
  return _cached_adapters
end

---Open the history picker
---@param opts table
---@return nil
local function open_history_picker(opts)
  local history = require("codecompanion.interactions.chat.history")
  local history_config = config.interactions.chat.history

  if not history_config or history_config.enabled == false then
    return require("codecompanion.utils").notify("Chat history is disabled", vim.log.levels.WARN)
  end

  local chats = history.list()
  if #chats == 0 then
    return require("codecompanion.utils").notify("No chat history found", vim.log.levels.INFO)
  end

  local picker = history_config.picker or "default"
  local items = vim.tbl_map(function(chat)
    return {
      id = chat.id,
      title = chat.title or "Untitled",
      updated_at = chat.updated_at,
      message_count = chat.message_count or 0,
      adapter = chat.adapter,
    }
  end, chats)

  local function format_item(item)
    local date = os.date("%Y-%m-%d %H:%M", item.updated_at)
    return string.format("[%s] %s (%d msgs)", date, item.title, item.message_count)
  end

  local function on_select(item)
    if item then
      history.open(item.id, { window_opts = opts.window_opts })
    end
  end

  if picker == "telescope" and pcall(require, "telescope") then
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    pickers
      .new({}, {
        prompt_title = "Chat History",
        finder = finders.new_table({
          results = items,
          entry_maker = function(entry)
            local display = format_item(entry)
            return {
              value = entry,
              display = display,
              ordinal = display,
            }
          end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr, _)
          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selection = action_state.get_selected_entry()
            if selection then
              on_select(selection.value)
            end
          end)
          return true
        end,
      })
      :find()
  elseif picker == "fzf_lua" and pcall(require, "fzf-lua") then
    local fzf = require("fzf-lua")
    local display_to_item = {}
    for _, item in ipairs(items) do
      display_to_item[format_item(item)] = item
    end
    fzf.fzf_exec(vim.tbl_keys(display_to_item), {
      prompt = "Chat History> ",
      actions = {
        ["default"] = function(selected)
          if selected and selected[1] then
            on_select(display_to_item[selected[1]])
          end
        end,
      },
    })
  elseif picker == "mini_pick" and pcall(require, "mini.pick") then
    local pick = require("mini.pick")
    pick.start({
      source = {
        name = "Chat History",
        items = vim.tbl_map(function(item)
          return { text = format_item(item), item = item }
        end, items),
        choose = function(chosen)
          if chosen then
            on_select(chosen.item)
          end
        end,
      },
    })
  elseif picker == "snacks" and pcall(require, "snacks") then
    local snacks = require("snacks")
    snacks.picker.pick({
      title = "Chat History",
      items = vim.tbl_map(function(item)
        return { text = format_item(item), data = item }
      end, items),
      format = function(item, _)
        return { { item.text } }
      end,
      confirm = function(picker_instance, item)
        picker_instance:close()
        if item then
          on_select(item.data)
        end
      end,
    })
  else
    vim.ui.select(items, {
      prompt = "Select chat from history:",
      format_item = format_item,
    }, on_select)
  end
end

---@type CodeCompanion.Command[]
return {
  {
    cmd = "CodeCompanion",
    callback = function(opts)
      -- Detect the user calling a prompt from the prompt library
      if opts.fargs[1] and string.sub(opts.fargs[1], 1, 1) == "/" then
        -- Get the prompt minus the slash
        local prompt = string.sub(opts.fargs[1], 2)

        if #opts.fargs > 1 then
          opts.user_prompt = table.concat(opts.fargs, " ", 2)
        end
        return codecompanion.prompt(prompt, opts)
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
      complete = function(arg_lead, cmdline, cursor_pos)
        local param_key = arg_lead:match("^(%w+)=$")
        if param_key == "adapter" then
          local adapters = get_adapters()
          return vim
            .iter(adapters)
            :map(function(adapter)
              return adapter
            end)
            :totable()
        end

        local args = vim.split(cmdline, "%s+")
        local current_arg_index = #args

        -- If we're typing in the middle of an argument, adjust the index
        if cmdline:sub(cursor_pos, cursor_pos) ~= " " and arg_lead ~= "" then
          current_arg_index = current_arg_index
        else
          current_arg_index = current_arg_index + 1
        end

        -- Always provide completions for adapters, prompt library, and variables
        local completions = {}
        local adapters = get_adapters()
        local prompt_aliases = require("codecompanion.helpers").get_prompt_aliases()

        -- Add adapters
        for _, adapter in ipairs(adapters) do
          table.insert(completions, "adapter=" .. adapter)
        end

        -- Add prompt library items
        vim.iter(prompt_aliases):each(function(k)
          table.insert(completions, "/" .. k)
        end)

        -- Add inline variables
        for key, _ in pairs(config.interactions.inline.variables) do
          if key ~= "opts" then
            table.insert(completions, "#{" .. key .. "}")
          end
        end

        -- Filter based on what the user is typing
        return vim
          .iter(completions)
          :filter(function(completion)
            return completion:find(vim.pesc(arg_lead), 1, true) == 1
          end)
          :totable()
      end,
    },
  },
  {
    cmd = "CodeCompanionChat",
    callback = function(opts)
      local params = {}
      local prompt = {}
      local subcommand = nil

      for _, arg in ipairs(opts.fargs) do
        local key, value = arg:match("^(%w+)=(.+)$")
        if key and value then
          params[key] = value
        elseif arg:lower() == "toggle" or arg:lower() == "add" or arg:lower() == "refreshcache" then
          subcommand = arg:lower()
        else
          -- Anything else is a prompt
          table.insert(prompt, arg)
        end
      end

      opts.params = params
      opts.subcommand = subcommand

      if #prompt > 0 then
        opts.user_prompt = table.concat(prompt, " ")
        opts.args = opts.user_prompt
      end

      codecompanion.chat(opts)
    end,
    opts = {
      desc = "Work with a CodeCompanion chat buffer",
      range = true,
      nargs = "*",
      -- Reference:
      -- https://github.com/nvim-neorocks/nvim-best-practices?tab=readme-ov-file#speaking_head-user-commands
      complete = function(arg_lead, cmdline, _cursor_pos)
        -- Check if we're completing a parameter value (e.g., "adapter=" or "model=")
        local param_key = arg_lead:match("^(%w+)=$")
        if param_key == "adapter" then
          return get_adapters()
        elseif param_key == "model" then
          -- Extract the adapter from the command line
          local adapter_name = cmdline:match("adapter=(%S+)")
          if adapter_name then
            local config_adapters = vim.tbl_deep_extend("force", {}, config.adapters.http)
            local adapter_config = config_adapters[adapter_name]
            if adapter_config then
              local ok, adapter = pcall(require("codecompanion.adapters").resolve, adapter_config)

              if ok and adapter and adapter.type == "http" then
                if adapter.schema and adapter.schema.model and adapter.schema.model.choices then
                  local choices = adapter.schema.model.choices

                  if type(choices) == "function" then
                    local ok_fn, result = pcall(choices, adapter, { async = false })
                    if ok_fn and result then
                      choices = result
                    else
                      return {}
                    end
                  end

                  -- Extract model names from choices (if choices is not nil)
                  if type(choices) == "table" then
                    if vim.islist(choices) then
                      return choices
                    else
                      return vim.tbl_keys(choices)
                    end
                  end
                end
              end
            end
          end
          return {}
        elseif param_key == "command" then
          -- Extract the adapter from the command line
          local adapter_name = cmdline:match("adapter=(%S+)")
          if adapter_name then
            local config_adapters = vim.tbl_deep_extend("force", {}, config.adapters.acp)
            local adapter_config = config_adapters[adapter_name]
            if adapter_config then
              local ok, adapter = pcall(require("codecompanion.adapters").resolve, adapter_config)

              if ok and adapter.commands then
                local commands_list = vim
                  .iter(adapter.commands)
                  :filter(function(k, _)
                    return k ~= "selected"
                  end)
                  :map(function(key, _)
                    if type(key) == "string" then
                      return key
                    end
                  end)
                  :totable()

                table.sort(commands_list)

                return commands_list
              end
              return {}
            end
          end
        end

        -- Only show general completions when at the start (no partial param typed)
        if cmdline:match("^['<,'>]*CodeCompanionChat[!]*%s+$") or arg_lead == "" then
          local completions = {
            "adapter=",
            "command=",
            "model=",
            "Toggle",
            "Add",
            "RefreshCache",
          }

          return vim
            .iter(completions)
            :filter(function(key)
              return key:find(vim.pesc(arg_lead), 1, true) == 1
            end)
            :totable()
        end

        return {}
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
      if opts.fargs[1] and opts.fargs[1]:lower() == "refresh" then
        local context = require("codecompanion.utils.context").get(vim.api.nvim_get_current_buf())
        require("codecompanion.actions").refresh_cache(context)
      end
      codecompanion.actions(opts)
    end,
    opts = {
      desc = "Open the CodeCompanion actions palette",
      range = true,
      nargs = "*",
      complete = function(arg_lead, cmdline, _cursor_pos)
        return { "refresh" }
      end,
    },
  },
  {
    cmd = "CodeCompanionHistory",
    callback = function(opts)
      local history = require("codecompanion.interactions.chat.history")
      local subcommand = opts.fargs[1] and opts.fargs[1]:lower()

      if subcommand == "save" then
        local chat = codecompanion.last_chat()
        if chat then
          local id = history.save(chat)
          if id then
            require("codecompanion.utils").notify("Chat saved to history", vim.log.levels.INFO)
          end
        else
          require("codecompanion.utils").notify("No active chat to save", vim.log.levels.WARN)
        end
      elseif subcommand == "last" then
        local last = history.open_last()
        if not last then
          require("codecompanion.utils").notify("No chat history found", vim.log.levels.INFO)
        end
      elseif subcommand == "clear" then
        vim.ui.select({ "Yes", "No" }, { prompt = "Clear all chat history?" }, function(choice)
          if choice == "Yes" then
            history.clear()
            require("codecompanion.utils").notify("Chat history cleared", vim.log.levels.INFO)
          end
        end)
      else
        open_history_picker(opts)
      end
    end,
    opts = {
      desc = "Browse and manage chat history",
      range = false,
      nargs = "?",
      complete = function(arg_lead, cmdline, _cursor_pos)
        local completions = { "save", "last", "clear" }
        return vim
          .iter(completions)
          :filter(function(c)
            return c:find(vim.pesc(arg_lead), 1, true) == 1
          end)
          :totable()
      end,
    },
  },
}
