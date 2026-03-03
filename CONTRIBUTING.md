# Contributing to OpenClaw Docker Stack

Thank you for taking the time to contribute! Here's how to get involved.

## Ways to Contribute

- **Bug reports** — open an issue with the bug report template
- **Feature requests** — open an issue with the feature request template
- **Pull requests** — fix bugs, improve docs, add GPU/model support
- **Share** — star the repo and share it with others running local LLMs

## Development Setup

```bash
git clone https://github.com/CloudsDocker/OpenClaw.git
cd OpenClaw
cp .env.example .env
# Set your token in .env
docker compose up -d
```

## Pull Request Guidelines

1. Fork the repo and create a branch from `main`
2. Test your change with `docker compose up -d --build`
3. Update `README.md` if you change behaviour or add new config options
4. Open a PR with a clear description of what and why

## Reporting Bugs

Include in your bug report:
- GPU model and VRAM
- OS (Linux distro or WSL2 version)
- Docker version (`docker --version`)
- Relevant logs (`docker compose logs openclaw | tail -50`)

## Code Style

- Shell scripts: POSIX sh compatible, no bashisms
- Keep the `entrypoint.sh` steps clearly numbered and commented
- Prefer simple and readable over clever

## Questions

Open a [GitHub Discussion](https://github.com/CloudsDocker/OpenClaw/discussions) for general questions.
