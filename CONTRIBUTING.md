# Contributing to MariaDB Backup System

Thank you for your interest in contributing to the MariaDB Backup System! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- Docker and Docker Compose
- Bash shell (Linux/macOS/WSL)
- Basic understanding of MariaDB/MySQL
- Git

### Development Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/xiLight/mariadb-backup-system.git
   cd mariadb-backup-system
   ```
3. Run the installation:
   ```bash
   make install
   ```
4. Run health check:
   ```bash
   make health
   ```

## Development Guidelines

### Code Style

- Use 2 spaces for indentation in shell scripts
- Follow existing naming conventions
- Add comments for complex logic
- Use meaningful variable names
- Keep functions small and focused

### Shell Script Guidelines

```bash
#!/bin/bash
# Always use strict mode
set -e

# Use functions for reusable code
function log_info() {
  echo "[INFO] $1"
}

# Use proper error handling
command || handle_error "Command failed"
```

### Testing

Before submitting changes:

1. Run the health check:
   ```bash
   make health-test
   ```

2. Test backup operations:
   ```bash
   make backup-full
   make backup
   ```

3. Test restore operations:
   ```bash
   make restore
   ```

4. Verify cleanup works:
   ```bash
   make cleanup
   ```

### Documentation

- Update README.md for user-facing changes
- Add inline comments for complex logic
- Update configuration examples if needed
- Include usage examples for new features

## Submitting Changes

### Pull Request Process

1. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Make your changes and test thoroughly

3. Commit with clear messages:
   ```bash
   git commit -m "Add feature: description of what was added"
   ```

4. Push to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```

5. Create a Pull Request

### Pull Request Guidelines

- Provide a clear description of changes
- Include the motivation for the change
- Test your changes thoroughly
- Update documentation as needed
- Follow the existing code style

### Commit Message Format

Use clear, descriptive commit messages:

```
type: brief description

Optional longer description explaining the change in more detail.

Fixes #123
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

## Bug Reports

When reporting bugs, please include:

1. Operating system and version
2. Docker version
3. Steps to reproduce
4. Expected behavior
5. Actual behavior
6. Relevant log files
7. Configuration files (remove sensitive data)

### Bug Report Template

```markdown
## Bug Description
Brief description of the bug

## Environment
- OS: Ubuntu 20.04
- Docker: 20.10.x
- Docker Compose: 1.29.x

## Steps to Reproduce
1. Step one
2. Step two
3. Step three

## Expected Behavior
What should happen

## Actual Behavior
What actually happened

## Logs
```
Relevant log output
```

## Additional Context
Any other relevant information
```

## Feature Requests

For feature requests, please include:

1. Use case description
2. Proposed solution
3. Alternative solutions considered
4. Additional context

## Development Areas

Areas where contributions are especially welcome:

### High Priority
- Performance improvements
- Security enhancements
- Error handling improvements
- Documentation improvements

### Medium Priority
- New backup strategies
- Additional database support
- Monitoring and alerting
- Web UI for management

### Low Priority
- Cloud storage integration
- Backup verification tools
- Advanced scheduling
- Backup analytics

## Code Review Process

1. All submissions require review
2. Maintainers will review PRs promptly
3. Changes may be requested before merging
4. CI/CD must pass before merging

## Security

For security issues:

1. **DO NOT** open public issues
2. Email security concerns privately
3. Include detailed reproduction steps
4. Allow time for fixes before disclosure

## Recognition

Contributors will be recognized in:
- GitHub contributors list
- README acknowledgments
- Release notes for significant contributions

## Questions?

- Open a GitHub issue for technical questions
- Use discussions for general questions
- Join our community chat (if available)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing! 🎉
