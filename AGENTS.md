# Agents Guide

## Commit Convention

This project uses [Conventional Commits](https://www.conventionalcommits.org/).

Format: `<type>: <description>`

Common types:
- `feat` – new feature
- `fix` – bug fix
- `chore` – maintenance, dependency updates, tooling
- `docs` – documentation only
- `refactor` – code restructuring without behavior change
- `ci` – CI/CD pipeline changes
- `test` – adding or updating tests
- `style` – formatting, whitespace

Examples:
```
feat: add services.strata.openFirewall
fix: pin ggml to the commit strata 0.2.13 expects
chore: update strata to 0.2.13
docs: document gpuTargets overrides
ci: add auto-updating workflow
```

Keep the description lowercase and concise. No period at the end.

When the change is non-trivial, add a body to summarize what changed and why. Separate it from the subject with a blank line:

```
feat: add services.strata.openFirewall

Added platform-specific packages for x86_64-linux, aarch64-linux,
x86_64-darwin, and aarch64-darwin. Each platform pulls the correct
Aspire CLI binary from upstream.
```
