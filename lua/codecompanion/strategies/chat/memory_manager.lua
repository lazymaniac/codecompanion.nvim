--=============================================================================
-- Memory Manager - Handles memory file maintenance and cleanup operations
--=============================================================================

local Path = require("plenary.path")
local log = require("codecompanion.utils.log")
local scandir = require("plenary.scandir")

local fmt = string.format

-- Memory persistence constants
local MEMORY_DIR = vim.fn.stdpath("data") .. "/codecompanion/memory"

---@class CodeCompanion.Chat.MemoryManager
local MemoryManager = {}

---Get all memory files in the memory directory
---@return table Array of memory file paths
function MemoryManager.get_all_memory_files()
  local memory_dir = Path:new(MEMORY_DIR)
  if not memory_dir:exists() then
    return {}
  end

  local files = scandir.scan_dir(MEMORY_DIR, {
    depth = 1,
    search_pattern = "%.json$",
  })

  return files or {}
end

---Get memory file statistics
---@return table Statistics about all memory files
function MemoryManager.get_memory_stats()
  local files = MemoryManager.get_all_memory_files()
  local total_size = 0
  local oldest_date = math.huge
  local newest_date = 0
  local valid_files = 0
  local invalid_files = 0

  for _, file_path in ipairs(files) do
    local file = Path:new(file_path)
    local stat = file:stat()

    if stat then
      total_size = total_size + stat.size
      oldest_date = math.min(oldest_date, stat.mtime.sec)
      newest_date = math.max(newest_date, stat.mtime.sec)

      -- Try to parse the file to check if it's valid
      local success, content = pcall(function()
        return file:read()
      end)

      if success then
        local parse_success = pcall(vim.json.decode, content)
        if parse_success then
          valid_files = valid_files + 1
        else
          invalid_files = invalid_files + 1
        end
      else
        invalid_files = invalid_files + 1
      end
    end
  end

  return {
    total_files = #files,
    valid_files = valid_files,
    invalid_files = invalid_files,
    total_size_bytes = total_size,
    total_size_mb = math.floor(total_size / 1024 / 1024 * 100) / 100,
    oldest_file_date = oldest_date ~= math.huge and oldest_date or nil,
    newest_file_date = newest_date ~= 0 and newest_date or nil,
    memory_dir = MEMORY_DIR,
  }
end

---Clean up old or invalid memory files
---@param options? table Cleanup options
---@return table Results of cleanup operation
function MemoryManager.cleanup_memory_files(options)
  options = options or {}
  local max_age_days = options.max_age_days or 30 -- Default: 30 days
  local remove_invalid = options.remove_invalid ~= false -- Default: true
  local dry_run = options.dry_run or false -- Default: false

  local files = MemoryManager.get_all_memory_files()
  local current_time = os.time()
  local max_age_seconds = max_age_days * 24 * 60 * 60

  local results = {
    processed = 0,
    removed_old = 0,
    removed_invalid = 0,
    errors = 0,
    removed_files = {},
    error_files = {},
  }

  for _, file_path in ipairs(files) do
    results.processed = results.processed + 1
    local file = Path:new(file_path)
    local stat = file:stat()
    local should_remove = false
    local reason = ""

    if not stat then
      should_remove = remove_invalid
      reason = "Could not stat file"
      results.removed_invalid = results.removed_invalid + 1
    else
      -- Check age
      local age_seconds = current_time - stat.mtime.sec
      if age_seconds > max_age_seconds then
        should_remove = true
        reason = fmt("File older than %d days", max_age_days)
        results.removed_old = results.removed_old + 1
      else
        -- Check validity
        if remove_invalid then
          local success, content = pcall(function()
            return file:read()
          end)

          if success then
            local parse_success, memory_data = pcall(vim.json.decode, content)
            if not parse_success or not memory_data.entries or type(memory_data.entries) ~= "table" then
              should_remove = true
              reason = "Invalid JSON structure"
              results.removed_invalid = results.removed_invalid + 1
            end
          else
            should_remove = true
            reason = "Could not read file"
            results.removed_invalid = results.removed_invalid + 1
          end
        end
      end
    end

    if should_remove then
      table.insert(results.removed_files, {
        path = file_path,
        reason = reason,
      })

      if not dry_run then
        local success, err = pcall(function()
          file:rm()
        end)

        if not success then
          results.errors = results.errors + 1
          table.insert(results.error_files, {
            path = file_path,
            error = err,
          })
          log:error("[MemoryManager] Failed to remove %s: %s", file_path, err)
        end
      end
    end
  end

  if not dry_run then
    log:info(
      "[MemoryManager] Cleanup complete: processed %d files, removed %d old, removed %d invalid, %d errors",
      results.processed,
      results.removed_old,
      results.removed_invalid,
      results.errors
    )
  else
    log:info(
      "[MemoryManager] Dry run complete: would remove %d old files, %d invalid files",
      results.removed_old,
      results.removed_invalid
    )
  end

  return results
end

---Get detailed information about a specific memory file
---@param memory_id string The memory ID
---@return table|nil Detailed memory file information
function MemoryManager.get_memory_file_details(memory_id)
  local file_path = MEMORY_DIR .. "/" .. memory_id .. ".json"
  local file = Path:new(file_path)

  if not file:exists() then
    return nil
  end

  local stat = file:stat()
  local success, content = pcall(function()
    return file:read()
  end)

  if not success then
    return {
      memory_id = memory_id,
      path = file_path,
      size = stat and stat.size or 0,
      modified = stat and stat.mtime.sec or 0,
      valid = false,
      error = "Could not read file",
    }
  end

  local parse_success, memory_data = pcall(vim.json.decode, content)
  if not parse_success then
    return {
      memory_id = memory_id,
      path = file_path,
      size = stat.size,
      modified = stat.mtime.sec,
      valid = false,
      error = "Invalid JSON",
    }
  end

  return {
    memory_id = memory_id,
    path = file_path,
    size = stat.size,
    modified = stat.mtime.sec,
    valid = true,
    data = memory_data,
    entry_count = memory_data.entries and #memory_data.entries or 0,
    adapter_name = memory_data.adapter_name,
    created_at = memory_data.created_at,
    last_updated = memory_data.last_updated,
  }
end

---List all memory files with basic information
---@param options? table Listing options
---@return table Array of memory file information
function MemoryManager.list_memory_files(options)
  options = options or {}
  local include_invalid = options.include_invalid or false
  local sort_by = options.sort_by or "modified" -- "modified", "size", "entries", "memory_id"
  local reverse = options.reverse or false

  local files = MemoryManager.get_all_memory_files()
  local file_infos = {}

  for _, file_path in ipairs(files) do
    local memory_id = Path:new(file_path):stem()
    local info = MemoryManager.get_memory_file_details(memory_id)

    if info and (info.valid or include_invalid) then
      table.insert(file_infos, info)
    end
  end

  -- Sort files
  table.sort(file_infos, function(a, b)
    local a_val, b_val

    if sort_by == "modified" then
      a_val, b_val = a.modified, b.modified
    elseif sort_by == "size" then
      a_val, b_val = a.size, b.size
    elseif sort_by == "entries" then
      a_val, b_val = a.entry_count or 0, b.entry_count or 0
    elseif sort_by == "memory_id" then
      a_val, b_val = a.memory_id, b.memory_id
    else
      a_val, b_val = a.modified, b.modified
    end

    if reverse then
      return a_val > b_val
    else
      return a_val < b_val
    end
  end)

  return file_infos
end

---Export memory file to a different format
---@param memory_id string The memory ID to export
---@param format string Export format ("json", "text", "markdown")
---@param output_path? string Optional output path
---@return string|nil Exported content or nil on error
function MemoryManager.export_memory_file(memory_id, format, output_path)
  local details = MemoryManager.get_memory_file_details(memory_id)
  if not details or not details.valid then
    log:error("[MemoryManager] Cannot export invalid memory file %s", memory_id)
    return nil
  end

  local content
  if format == "json" then
    content = vim.json.encode(details.data)
  elseif format == "text" then
    local lines = {
      fmt("Memory ID: %s", memory_id),
      fmt("Adapter: %s", details.adapter_name or "unknown"),
      fmt("Created: %s", details.created_at and os.date("%Y-%m-%d %H:%M:%S", details.created_at) or "unknown"),
      fmt("Updated: %s", details.last_updated and os.date("%Y-%m-%d %H:%M:%S", details.last_updated) or "unknown"),
      fmt("Entries: %d", details.entry_count),
      "",
    }

    for i, entry in ipairs(details.data.entries or {}) do
      table.insert(
        lines,
        fmt("--- Entry %d (Cycles %d-%d, %d messages) ---", i, entry.start_cycle, entry.end_cycle, entry.original_count)
      )
      table.insert(lines, entry.summary)
      table.insert(lines, "")
    end

    content = table.concat(lines, "\n")
  elseif format == "markdown" then
    local lines = {
      fmt("# Memory Export: %s", memory_id),
      "",
      fmt("- **Adapter:** %s", details.adapter_name or "unknown"),
      fmt("- **Created:** %s", details.created_at and os.date("%Y-%m-%d %H:%M:%S", details.created_at) or "unknown"),
      fmt(
        "- **Updated:** %s",
        details.last_updated and os.date("%Y-%m-%d %H:%M:%S", details.last_updated) or "unknown"
      ),
      fmt("- **Entries:** %d", details.entry_count),
      "",
    }

    for i, entry in ipairs(details.data.entries or {}) do
      table.insert(lines, fmt("## Entry %d", i))
      table.insert(
        lines,
        fmt("**Cycles:** %d-%d | **Messages:** %d", entry.start_cycle, entry.end_cycle, entry.original_count)
      )
      table.insert(lines, "")
      table.insert(lines, entry.summary)
      table.insert(lines, "")
    end

    content = table.concat(lines, "\n")
  else
    log:error("[MemoryManager] Unknown export format: %s", format)
    return nil
  end

  if output_path then
    local output_file = Path:new(output_path)
    local success, err = pcall(function()
      output_file:write(content, "w")
    end)

    if not success then
      log:error("[MemoryManager] Failed to write export to %s: %s", output_path, err)
      return nil
    end

    log:info("[MemoryManager] Exported memory %s to %s (%s format)", memory_id, output_path, format)
  end

  return content
end

return MemoryManager
