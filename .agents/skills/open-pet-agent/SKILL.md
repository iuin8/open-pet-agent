```markdown
# open-pet-agent Development Patterns

> Auto-generated skill from repository analysis

## Overview
This skill teaches the core development patterns and conventions used in the `open-pet-agent` Swift codebase. It covers file organization, code style, commit practices, and testing patterns, providing practical examples and suggested commands for efficient collaboration and contribution.

## Coding Conventions

### File Naming
- **Pattern:** PascalCase  
  **Example:**  
  ```swift
  // Good
  PetAgent.swift

  // Bad
  pet_agent.swift
  petagent.swift
  ```

### Import Style
- **Pattern:** Relative imports  
  **Example:**  
  ```swift
  import Foundation
  import MyModule // Relative to project structure
  ```

### Export Style
- **Pattern:** Named exports  
  **Example:**  
  ```swift
  public class PetAgent {
      // ...
  }
  ```

### Commit Messages
- **Pattern:** Conventional commits  
- **Prefixes:** `feat`, `chore`  
- **Average length:** 44 characters  
  **Example:**  
  ```
  feat: add basic pet agent behavior
  chore: update dependencies
  ```

## Workflows

### Feature Development
**Trigger:** When implementing a new feature  
**Command:** `/feature`

1. Create a new branch: `git checkout -b feat/short-description`
2. Implement the feature following coding conventions
3. Write or update relevant tests
4. Commit using the `feat:` prefix and a clear message
5. Open a pull request for review

### Chore Tasks
**Trigger:** When performing maintenance or non-feature updates  
**Command:** `/chore`

1. Create a new branch: `git checkout -b chore/short-description`
2. Make the necessary maintenance changes (e.g., update dependencies)
3. Commit using the `chore:` prefix and a clear message
4. Open a pull request for review

## Testing Patterns

- **Framework:** Unknown (ensure to check or specify in your PR)
- **File Pattern:** Test files are named with `*.test.*`  
  **Example:**  
  ```
  PetAgent.test.swift
  ```
- **Best Practice:** Place test files alongside the code they test or in a dedicated test directory.

## Commands
| Command    | Purpose                                  |
|------------|------------------------------------------|
| /feature   | Start a new feature development workflow  |
| /chore     | Start a maintenance or chore workflow     |
```