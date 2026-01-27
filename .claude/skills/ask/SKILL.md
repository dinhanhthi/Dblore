---
name: ask
description: Answer technical and architectural questions about SQLNotebook codebase
argument-hint: [your question]
allowed-tools: Read, Grep, Glob, WebSearch
---

# Ask: $ARGUMENTS

## Question Answering Mode

Answer the following question: **$ARGUMENTS**

### Guidelines

1. **Search the codebase** to find relevant code and patterns
2. **Read actual implementation** to provide accurate answers
3. **Reference specific files and line numbers** (e.g., `FileName.swift:123`)
4. **Explain concepts clearly** with examples when helpful

### Response Format

- Start with a direct answer to the question
- Provide code references: `[FileName.swift:123](path/to/FileName.swift#L123)`
- Include relevant code snippets if helpful
- Explain the "why" behind design decisions when known

### Context Sources

When answering, consider:
- `CLAUDE.md` - Project guidelines and patterns
- `docs/` - Project documentation
- Source code in `SQLNotebook/` - Actual implementation
- `SQLNotebookTests/` - Test examples and usage patterns

### Example Topics

- Architecture questions: "How does the connection manager work?"
- Pattern questions: "How should I use @Observable in this project?"
- Code location: "Where is query execution handled?"
- Best practices: "What's the correct way to add a new feature?"
