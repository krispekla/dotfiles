# Rust toolchain, only if installed on this machine
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
export EDITOR=nvim

# Secrets and machine-specific exports live here, never in the repo
[ -f "$HOME/.zshenv.local" ] && . "$HOME/.zshenv.local"
