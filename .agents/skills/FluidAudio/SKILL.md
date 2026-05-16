```markdown
# FluidAudio Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches the core development patterns and conventions used in the FluidAudio Swift codebase. It covers file naming, import/export styles, commit message practices, and testing patterns. While no specific frameworks or automated workflows are detected, this guide provides practical examples and command suggestions to streamline your development process in FluidAudio.

## Coding Conventions

### File Naming
- **Style:** `snake_case`
- **Example:**  
  ```swift
  // Good
  audio_processor.swift

  // Bad
  AudioProcessor.swift
  ```

### Import Style
- **Style:** Relative imports
- **Example:**  
  ```swift
  import "./audio_utils"
  ```

### Export Style
- **Style:** Named exports
- **Example:**  
  ```swift
  public func processAudio(_ input: AudioBuffer) -> AudioBuffer
  ```

### Commit Messages
- **Type:** Freeform, with occasional `wip` prefixes
- **Average Length:** ~27 characters
- **Example:**  
  ```
  wip: add basic audio filter
  fix: correct buffer overflow
  ```

## Workflows

### Adding a New Audio Module
**Trigger:** When you need to implement a new audio processing feature  
**Command:** `/add-audio-module`

1. Create a new Swift file using `snake_case` (e.g., `new_audio_module.swift`)
2. Implement your feature using named exports
3. Use relative imports to include dependencies
4. Write corresponding test in a `*.test.*` file
5. Commit with a descriptive message (optionally prefix with `wip` if incomplete)

### Refactoring Existing Code
**Trigger:** When improving or restructuring existing code  
**Command:** `/refactor`

1. Identify files to refactor (ensure `snake_case` naming)
2. Update imports to use relative paths if needed
3. Ensure all exports are named
4. Update or add tests as necessary
5. Commit changes with a clear message

## Testing Patterns

- **Framework:** Unknown (no explicit framework detected)
- **Test File Pattern:** Files matching `*.test.*`
- **Example:**
  ```swift
  // File: audio_processor.test.swift

  import "./audio_processor"

  func testProcessAudio() {
      // Test implementation here
  }
  ```

## Commands
| Command            | Purpose                                      |
|--------------------|----------------------------------------------|
| /add-audio-module  | Scaffold and implement a new audio module    |
| /refactor          | Refactor existing code following conventions |
```
