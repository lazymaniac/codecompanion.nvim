local ChainOfThought = {}
ChainOfThought.__index = ChainOfThought

-- Constructor
function ChainOfThought.new(problem)
  local self = setmetatable({}, ChainOfThought)
  self.problem = problem or ""
  self.steps = {}
  self.current_step = 0
  self.completed = false
  self.conclusion = nil
  return self
end

-- Step types and their validation criteria
local STEP_TYPES = {
  analysis = "Analysis and exploration of the problem",
  reasoning = "Logical deduction and inference",
  task = "Actionable implementation step",
  validation = "Verification and testing",
}

-- Validate step content based on type
function ChainOfThought:validate_step(step_type, content, reasoning)
  if not STEP_TYPES[step_type] then
    return false, "Invalid step type"
  end

  if not content or content:len() < 10 then
    return false, "Content too short or empty"
  end

  if not reasoning or reasoning:len() < 20 then
    return false, "Reasoning explanation insufficient"
  end

  return true, "Valid step"
end

-- Add a step to the chain
function ChainOfThought:add_step(step_type, content, reasoning, step_id)
  if self.completed then
    return false, "Chain is already completed"
  end

  local valid, message = self:validate_step(step_type, content, reasoning)
  if not valid then
    return false, message
  end

  self.current_step = self.current_step + 1
  local step = {
    id = step_id or ("step_" .. self.current_step),
    type = step_type,
    content = content,
    reasoning = reasoning,
    step_number = self.current_step,
    timestamp = os.time(),
  }

  table.insert(self.steps, step)
  return true, "Step added successfully"
end

-- View the complete chain
function ChainOfThought:view_chain()
  print("=== CHAIN OF THOUGHT ===")
  local problem_str = type(self.problem) == "table" and vim.inspect(self.problem) or tostring(self.problem)
  print("Problem: " .. problem_str)
  print("")

  for i, step in ipairs(self.steps) do
    print(string.format("Step %d: %s (%s)", i, step.id, step.type))
    print("Content: " .. step.content)
    print("Reasoning: " .. step.reasoning)
    print("")
  end

  if self.completed and self.conclusion then
    print("CONCLUSION: " .. self.conclusion)
  end

  print(string.format("Chain Status: %s", self.completed and "completed" or "active"))
  print(string.format("Total Steps: %d", #self.steps))
end

-- Complete the chain with a conclusion
function ChainOfThought:complete_chain(conclusion)
  if not conclusion or conclusion:len() < 20 then
    return false, "Conclusion must be substantial"
  end

  self.conclusion = conclusion
  self.completed = true
  return true, "Chain completed successfully"
end

-- Reflect on the reasoning process
function ChainOfThought:reflect()
  local insights = {}
  local improvements = {}

  -- Analyze step distribution
  local step_counts = {}
  for _, step in ipairs(self.steps) do
    step_counts[step.type] = (step_counts[step.type] or 0) + 1
  end

  table.insert(insights, string.format("Step distribution: %s", table.concat(self:table_to_strings(step_counts), ", ")))

  -- Check for logical progression
  local has_analysis = step_counts.analysis and step_counts.analysis > 0
  local has_reasoning = step_counts.reasoning and step_counts.reasoning > 0
  local has_tasks = step_counts.task and step_counts.task > 0
  local has_validation = step_counts.validation and step_counts.validation > 0

  if has_analysis and has_reasoning and has_tasks then
    table.insert(insights, "Good logical progression from analysis to implementation")
  else
    table.insert(improvements, "Consider including analysis, reasoning, and task steps")
  end

  if not has_validation then
    table.insert(improvements, "Add validation steps to verify reasoning")
  end

  return {
    total_steps = #self.steps,
    insights = insights,
    improvements = improvements,
    completion_status = self.completed,
  }
end

-- Helper function to convert table to strings
function ChainOfThought:table_to_strings(t)
  local result = {}
  for k, v in pairs(t) do
    table.insert(result, k .. ":" .. tostring(v))
  end
  return result
end

-- Export the module
return {
  ChainOfThought = ChainOfThought,
}
