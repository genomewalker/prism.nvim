--- prism.nvim builtin actions module
--- Predefined code actions with prompt templates
--- @module prism.actions.builtin

local M = {}

--- Action output types
--- "floating" - show in floating window
--- "inline" - apply changes inline to buffer
--- "terminal" - run in claude terminal
--- "replace" - replace selection with output
M.output_types = {
  FLOATING = "floating",
  INLINE = "inline",
  TERMINAL = "terminal",
  REPLACE = "replace",
}

--- Explain action - explain selected code
M.explain = {
  name = "Explain",
  icon = "",
  description = "Explain what this code does",
  prompt_template = [[Explain this code from {file} ({filetype}):

```{filetype}
{selection}
```

Provide a clear, concise explanation of what this code does, including:
- The purpose and functionality
- Key logic and control flow
- Any notable patterns or techniques used]],
  requires_selection = true,
  output = "floating",
}

--- Fix action - fix issues in code
M.fix = {
  name = "Fix",
  icon = "",
  description = "Fix issues in this code",
  prompt_template = [[Fix any issues in this code from {file} ({filetype}):

```{filetype}
{selection}
```

{context}

Identify and fix any bugs, errors, or issues. Return only the corrected code without explanation.]],
  requires_selection = true,
  output = "inline",
}

--- Refactor action - improve code structure
M.refactor = {
  name = "Refactor",
  icon = "",
  description = "Refactor and improve this code",
  prompt_template = [[Refactor this code from {file} ({filetype}) to improve readability and maintainability:

```{filetype}
{selection}
```

Apply best practices for {filetype}. Return only the refactored code without explanation.]],
  requires_selection = true,
  output = "inline",
}

--- Test action - generate tests
M.test = {
  name = "Test",
  icon = "",
  description = "Generate tests for this code",
  prompt_template = [[Generate comprehensive tests for this code from {file} ({filetype}):

```{filetype}
{selection}
```

Create unit tests that cover:
- Normal cases
- Edge cases
- Error handling

Use appropriate testing framework for {filetype}.]],
  requires_selection = true,
  output = "terminal",
}

--- Document action - add documentation
M.document = {
  name = "Document",
  icon = "",
  description = "Add documentation to this code",
  prompt_template = [[Add comprehensive documentation to this code from {file} ({filetype}):

```{filetype}
{selection}
```

Add appropriate documentation comments following {filetype} conventions. Include:
- Function/method descriptions
- Parameter documentation
- Return value documentation
- Usage examples where helpful

Return only the documented code.]],
  requires_selection = true,
  output = "inline",
}

--- Optimize action - improve performance
M.optimize = {
  name = "Optimize",
  icon = "",
  description = "Optimize this code for performance",
  prompt_template = [[Optimize this code from {file} ({filetype}) for better performance:

```{filetype}
{selection}
```

Improve performance while maintaining correctness. Consider:
- Algorithm efficiency
- Memory usage
- Unnecessary operations

Return only the optimized code without explanation.]],
  requires_selection = true,
  output = "inline",
}

--- Review action - code review
M.review = {
  name = "Review",
  icon = "",
  description = "Review this code",
  prompt_template = [[Review this code from {file} ({filetype}):

```{filetype}
{selection}
```

Provide a thorough code review covering:
- Potential bugs or issues
- Code quality and readability
- Best practices adherence
- Security considerations
- Suggestions for improvement]],
  requires_selection = true,
  output = "floating",
}

--- TypeCheck action - add type annotations
M.typecheck = {
  name = "Add Types",
  icon = "",
  description = "Add type annotations",
  prompt_template = [[Add type annotations to this code from {file} ({filetype}):

```{filetype}
{selection}
```

Add comprehensive type annotations following {filetype} conventions. Return only the typed code.]],
  requires_selection = true,
  output = "inline",
}

--- Simplify action - make code simpler
M.simplify = {
  name = "Simplify",
  icon = "",
  description = "Simplify this code",
  prompt_template = [[Simplify this code from {file} ({filetype}):

```{filetype}
{selection}
```

Make the code simpler and more readable while maintaining functionality. Remove unnecessary complexity. Return only the simplified code.]],
  requires_selection = true,
  output = "inline",
}

--- Chat action - open chat about selection
M.chat = {
  name = "Chat",
  icon = "",
  description = "Ask about this code",
  prompt_template = [[I have a question about this code from {file} ({filetype}):

```{filetype}
{selection}
```

{input}]],
  requires_selection = true,
  requires_input = true,
  input_prompt = "Ask about the code:",
  output = "terminal",
}

--- Complete action - complete code
M.complete = {
  name = "Complete",
  icon = "",
  description = "Complete this code",
  prompt_template = [[Complete this code from {file} ({filetype}):

```{filetype}
{selection}
```

Continue and complete the code logically. Return only the completed code.]],
  requires_selection = true,
  output = "replace",
}

--- Get all builtin actions
--- @return table<string, table> Actions
function M.all()
  return {
    explain = M.explain,
    fix = M.fix,
    refactor = M.refactor,
    test = M.test,
    document = M.document,
    optimize = M.optimize,
    review = M.review,
    typecheck = M.typecheck,
    simplify = M.simplify,
    chat = M.chat,
    complete = M.complete,
  }
end

--- Get list of action names
--- @return string[] Action names
function M.names()
  return {
    "explain",
    "fix",
    "refactor",
    "test",
    "document",
    "optimize",
    "review",
    "typecheck",
    "simplify",
    "chat",
    "complete",
  }
end

return M
