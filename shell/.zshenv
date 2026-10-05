# Rust toolchain, only if installed on this machine
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export EDITOR=nvim

# herdr reads a generated config with per-worktree colours (herdr/scripts/worktree-theme.py).
# Only once it exists, so a fresh machine falls back to config.toml.
[ -f "$HOME/.config/herdr/config.generated.toml" ] && export HERDR_CONFIG_PATH="$HOME/.config/herdr/config.generated.toml"

# Secrets and machine-specific exports live here, never in the repo
[ -f "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
