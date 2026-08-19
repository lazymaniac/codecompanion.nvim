local fmt = string.format

local M = {}

---Path relative to the cwd, tolerating a filepath the LLM never sent
---@param filepath string?
---@return string
M.display_path = function(filepath)
  if type(filepath) ~= "string" or filepath == "" then
    return "<no path given>"
  end
  return vim.fn.fnamemodify(filepath, ":.")
end

---Rejection message back to the LLM
---@param self CodeCompanion.Tools.Tool
---@param opts table
---@return nil
M.rejected = function(self, opts)
  opts = opts or {}

  local rejection = opts.message or "The user declined to execute the tool"
  if opts.opts and opts.opts.reason then
    rejection = fmt('%s, with the reason: "%s"', rejection, opts.opts.reason)
  end

  return opts.tools.chat:add_tool_output(self, rejection)
end

return M
