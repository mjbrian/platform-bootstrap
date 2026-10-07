eval "$(mise activate zsh)"
export AWS_PROFILE=lab
export PATH="$(brew --prefix libpq)/bin:$HOME/.krew/bin:$PATH"
[ -f "${0:A:h}/lab.local.zsh" ] && source "${0:A:h}/lab.local.zsh"
