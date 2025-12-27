# Load private/secret configuration first
[[ -f ~/.zshrc.secret ]] && source ~/.zshrc.secret

# Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
# Initialization code that may require console input (password prompts, [y/n]
# confirmations, etc.) must go above this block; everything else may go below.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# Oh My Zsh configuration
export ZSH="$PERSONAL_HOME_DIR/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git)
source $ZSH/oh-my-zsh.sh

# Git configuration
git config --global core.excludesfile ~/.gitignore_global

# Software used for ongoing side projects
export KAFKA_HOME="/opt/homebrew/Cellar/kafka/3.7.0"
export PATH=$KAFKA_HOME/bin:$PATH

# Kafka aliases
alias zookeeperstart='$KAFKA_HOME/bin/zookeeper-server-start $KAFKA_HOME/libexec/config/zookeeper.properties'
alias kafkastart='$KAFKA_HOME/bin/kafka-server-start $KAFKA_HOME/libexec/config/server.properties'
alias kafkastop='$KAFKA_HOME/bin/kafka-server-stop'
alias zkstop='$KAFKA_HOME/bin/zookeeper-server-stop'

# MongoDB aliases
alias mongolog='cd /opt/homebrew/var/log/mongodb'
alias mongod='brew services run mongodb-community'
alias mongod-status='brew services list'
alias mongod-stop='brew services stop mongodb-community'

# General aliases
alias src=source
# alias brewnew='brew update && brew upgrade && brew cleanup && brew doctor'
alias brewnew='brew update && brew upgrade && brew cleanup --prune=all && brew autoremove && brew doctor'
alias pip='pip3'
alias pipupgrade="pip list --outdated | grep -Ev \"Package|^-\" | awk '{print $1}'| while IFS= read -r line ; do pip3 install \"$line\" -U ; done"
alias ls='ls -lah --color=auto'
alias python='python3'
alias diskspace='du -shc .??* * | sort -hr'
alias zsrc='source ~/.zshrc'
alias dev='cd $PERSONAL_HOME_DIR/dev'
alias proj='cd $PERSONAL_HOME_DIR/dev/projects'
alias kaggle='$PERSONAL_HOME_DIR/dev/kaggle'
alias notes='subl $PERSONAL_HOME_DIR/notes'
alias todos='subl $PERSONAL_HOME_DIR/notes/todos.txt'
alias csprimer='cd $PERSONAL_HOME_DIR/dev/projects/csprimer'
alias cards='cd $PERSONAL_HOME_DIR/dev/projects/pytestbook/code && source ../venv/bin/activate'

# Functions
function emailcopy() {
  echo -n $PERSONAL_EMAIL | pbcopy
  echo "Email address copied to clipboard."
}

function githubcopy() {
  echo -n $PERSONAL_GITHUB | pbcopy
  echo "GitHub profile URL copied to clipboard."
}

function astrosync() {
  echo "Script started at: $(date)"
  cd $ASTRO_PROJECT_HOMEDIR
  npm run astro build
  rsync -av --delete -e \
    "ssh -i $ASTRO_SYNC_SSH_KEY -p 18765" \
    $ASTRO_SYNC_SOURCE \
    $ASTRO_SYNC_HOST:$ASTRO_SYNC_DEST
  echo "Script completed at: $(date)"
}

# Find files larger than 5 GB, sorted by size
big5() {
  local dir="${1:-$HOME}"

  echo "Scanning: $dir"
  echo "Showing files > 5 GB (may take a bit if dir is large)..."
  echo

  find "$dir" -type f -size +5G -print0 2>/dev/null \
    | xargs -0 ls -lh 2>/dev/null \
    | sort -k5 -h
}


# Aggressive dev-cache + Docker cleanup
purge_dev_caches() {
  echo "=== Docker prune (images, containers, volumes, build cache) ==="
  docker system prune -a --volumes -f

  echo
  echo "=== Deleting large dev/browser caches under ~/Library/Caches ==="

  rm -rf \
    "$HOME/Library/Caches/com.spotify.client" \
    "$HOME/Library/Caches/Homebrew" \
    "$HOME/Library/Caches/pip" \
    "$HOME/Library/Caches/JetBrains" \
    "$HOME/Library/Caches/BraveSoftware" \
    "$HOME/Library/Caches/go-build" \
    "$HOME/Library/Caches/Google" \
    "$HOME/Library/Caches/Firefox" \
    "$HOME/Library/Caches/Cypress" \
    "$HOME/Library/Caches/Sublime Text 3"

  echo
  echo "=== Cache size after purge ==="
  du -sh "$HOME/Library/Caches" 2>/dev/null || echo "No Caches dir?"
}



# NVM configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# Powerlevel10k theme (loaded after Oh My Zsh)
source $PERSONAL_HOME_DIR/powerlevel10k/powerlevel10k.zsh-theme

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

export PATH="$HOME/scripts:$PATH"

# ============================================
# DOTFILES MANAGEMENT
# ============================================
export DOTFILES="$HOME/dotfiles"
alias dotfiles="$DOTFILES/scripts/sync-dotfiles.sh"
alias dotbackup="$DOTFILES/scripts/sync-dotfiles.sh push"
alias dotrestore="$DOTFILES/scripts/sync-dotfiles.sh restore"
alias dotstatus="$DOTFILES/scripts/sync-dotfiles.sh status"
