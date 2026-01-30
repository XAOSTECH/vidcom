# Contributing to vidcom

Thank you for your interest in contributing! This document provides guidelines and steps for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [How to Contribute](#how-to-contribute)
- [Development Setup](#development-setup)
- [Pull Request Process](#pull-request-process)
- [Style Guidelines](#style-guidelines)

## Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/vidcom.git`
3. Add upstream remote: `git remote add upstream https://github.com/xaoscience/vidcom.git`
4. Create a branch: `git checkout -b feature/your-feature-name`

## How to Contribute

### Reporting Bugs

- Check existing issues first
- Use the bug report template
- Include reproduction steps
- Provide system/environment details

### Suggesting Features

- Check existing issues/discussions
- Clearly describe the use case
- Explain why this would benefit others

### Code Contributions

- Fix bugs
- Implement new features
- Improve documentation
- Add tests
- Optimise performance

## Development Setup

```bash
# Clone and enter directory
git clone https://github.com/xaoscience/vidcom.git
cd vidcom

# Install dependencies (if applicable)
# ./install.sh or npm install, etc.

# Run tests (if applicable)
# ./test.sh or npm test, etc.
```

## Pull Request Process

1. **Update your branch** with the latest upstream changes:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Make your changes** in focused, atomic commits

3. **Test your changes** thoroughly

4. **Push to your fork**:
   ```bash
   git push origin feature/your-feature-name
   ```

5. **Open a Pull Request** with:
   - Clear title and description
   - Reference to related issues
   - Screenshots/examples if applicable

6. **Address review feedback** promptly

## Style Guidelines

### Commit Messages

- Use present tense: "Add feature" not "Added feature"
- Use imperative mood: "Move cursor" not "Moves cursor"
- Limit first line to 72 characters
- Reference issues: "Fix #123"

### Code Style

- Follow existing code patterns
- Comment complex logic
- Keep functions focused and small
- Use meaningful variable names

### Shell Scripts

- Use `#!/usr/bin/env bash`
- Quote variables: `"$var"` not `$var`
- Use `[[ ]]` for conditionals
- Add error handling with `set -e`

---

## Questions?

Feel free to open a [Discussion](https://github.com/xaoscience/vidcom/discussions) for questions or ideas.

Thank you for contributing! 🙏
