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

syshealth() {
  # ── colors ────────────────────────────────────────────────────────────────
  local RED='\033[0;31m' YLW='\033[0;33m' GRN='\033[0;32m'
  local DIM='\033[2m'    BLD='\033[1m'    RST='\033[0m'

  # ── helpers ───────────────────────────────────────────────────────────────
  _bar() {
    local pct=${1:-0} width=24
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local color
    (( pct >= 90 )) && color=$RED || { (( pct >= 70 )) && color=$YLW || color=$GRN; }
    printf "${color}"
    (( filled > 0 )) && printf '█%.0s' $(seq 1 $filled)
    printf "${DIM}"
    (( empty  > 0 )) && printf '░%.0s' $(seq 1 $empty)
    printf "${RST}"
  }

  _pill() {
    local label=$1 level=$2
    case $level in
      ok)   printf " ${GRN}[✓ ${label}]${RST}" ;;
      warn) printf " ${YLW}[⚠ ${label}]${RST}" ;;
      crit) printf " ${RED}[✖ ${label}]${RST}" ;;
    esac
  }

  _header() { printf "\n${BLD}── %s${RST}%s\n" "$1" "$2"; }
  _hint()   { printf "  ${DIM}↳ %s${RST}\n" "$1"; }

  # ── PASS 1: collect all data ───────────────────────────────────────────────

  # CPU
  local cpu_out cores load1 load5 load15 user_pct sys_pct idle_pct
  cpu_out=$(top -l 1 -n 0 2>/dev/null)
  cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)
  read -r load1 load5 load15 <<< "$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2, $3, $4}')"
  read -r user_pct sys_pct idle_pct <<< "$(echo "$cpu_out" | awk -F'[: %]+' '/CPU usage/{print $3, $5, $7}')"
  local load_int=${load1%.*}
  local cpu_status; (( load_int >= cores )) && cpu_status="warn" || cpu_status="ok"
  local cpu_label;  (( load_int >= cores )) && cpu_label="load elevated" || cpu_label="load ok"

  # Memory
  local vm_out free_pages active inactive wired compressor
  vm_out=$(vm_stat 2>/dev/null)
  free_pages=$(echo "$vm_out" | awk '/Pages free/              {gsub(/\./,"",$3); print $3}')
  active=$(echo    "$vm_out" | awk '/Pages active/             {gsub(/\./,"",$3); print $3}')
  inactive=$(echo  "$vm_out" | awk '/Pages inactive/           {gsub(/\./,"",$3); print $3}')
  wired=$(echo     "$vm_out" | awk '/Pages wired down/         {gsub(/\./,"",$4); print $4}')
  compressor=$(echo "$vm_out"| awk '/Pages stored in compressor/{gsub(/\./,"",$5); print $5}')

  local free_gb active_gb inactive_gb wired_gb comp_gb
  free_gb=$(echo     "$free_pages" | awk '{printf "%.1f", $1*4096/1073741824}')
  active_gb=$(echo   "$active"     | awk '{printf "%.1f", $1*4096/1073741824}')
  inactive_gb=$(echo "$inactive"   | awk '{printf "%.1f", $1*4096/1073741824}')
  wired_gb=$(echo    "$wired"      | awk '{printf "%.1f", $1*4096/1073741824}')
  comp_gb=$(echo     "$compressor" | awk '{printf "%.1f", $1*4096/1073741824}')

  local total_bytes total_gb used_gb used_pct comp_int
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  total_gb=$(echo "$total_bytes" | awk '{printf "%.0f", $1/1073741824}')
  used_gb=$(echo "$free_gb $total_gb"  | awk '{printf "%.1f", $2-$1}')
  used_pct=$(echo "$used_gb $total_gb" | awk '{printf "%d",   ($1/$2)*100}')
  comp_int=${comp_gb%.*}

  local mem_status mem_label
  if   (( used_pct >= 95 )); then mem_status="crit"; mem_label="critical"
  elif (( used_pct >= 80 )); then mem_status="warn"; mem_label="pressure"
  else                             mem_status="ok";   mem_label="ok"; fi

  # Disk (capture for both actions and display)
  local disk_out
  disk_out=$(df -h 2>/dev/null | awk 'NR>1 && /^\/dev\// && !/disk[0-9]+s[0-9]+s[0-9]+$/ {print}')

  # Processes
  local ps_out ws_cpu top_proc_name top_proc_cpu
  ps_out=$(ps aux 2>/dev/null | sort -rk3)
  ws_cpu=$(echo "$ps_out" | awk '/WindowServer/ && !/awk/ {print int($3+0); exit}')
  top_proc_name=$(echo "$ps_out" | awk 'NR==2 {print $11}')
  top_proc_cpu=$(echo  "$ps_out" | awk 'NR==2 {print int($3+0)}')

  # File descriptors
  local fd_count fd_status fd_label
  fd_count=$(lsof 2>/dev/null | wc -l | tr -d ' ')
  if   (( fd_count >= 50000 )); then fd_status="crit"; fd_label="very high"
  elif (( fd_count >= 25000 )); then fd_status="warn"; fd_label="elevated"
  else                               fd_status="ok";   fd_label="normal"; fi

  # Thermals
  local thermal_out=""
  if command -v powermetrics &>/dev/null; then
    thermal_out=$(sudo -n powermetrics --samplers smc -n 1 2>/dev/null)
  fi

  # ── PASS 2: derive action items ───────────────────────────────────────────
  local -a _crit _warn _info

  # CPU
  (( load_int >= cores )) && \
    _warn+=("Load avg ${load1} exceeds core count (${cores}) — likely memory pressure or I/O wait")

  # Memory
  (( used_pct >= 95 )) && \
    _crit+=("Memory critical (${used_pct}% used, ${free_gb}GB free) — quit unused apps now")
  (( used_pct >= 80 && used_pct < 95 )) && \
    _warn+=("Memory pressure (${used_pct}% used) — close Chrome tabs or heavy apps to relieve")
  (( comp_int > 4 )) && \
    _warn+=("${comp_gb}GB in compressor — macOS is struggling to avoid swap; free RAM to cut CPU overhead")

  # Disk
  while IFS= read -r line; do
    local dpct dmount
    dpct=$(echo "$line"   | awk '{gsub(/%/,"",$5); print $5+0}')
    dmount=$(echo "$line" | awk '{print $6}')
    (( dpct >= 90 )) && \
      _crit+=("Disk ${dmount} at ${dpct}% — free space now: rm -rf ~/.Trash/* && brew cleanup")
    (( dpct >= 75 && dpct < 90 )) && \
      _warn+=("Disk ${dmount} at ${dpct}% — consider clearing ~/Library/Caches or old build artifacts")
  done <<< "$disk_out"

  # WindowServer
  (( ws_cpu >= 20 )) && \
    _warn+=("WindowServer at ${ws_cpu}% CPU — reduce open windows/displays or restart your session")

  # File descriptors
  (( fd_count >= 50000 )) && \
    _crit+=("File descriptors very high (${fd_count}) — possible leak: lsof | awk '{print \$1}' | sort | uniq -c | sort -rn | head")
  (( fd_count >= 25000 && fd_count < 50000 )) && \
    _warn+=("File descriptors elevated (${fd_count}) — monitor for growth")

  # Thermals
  if [[ -n "$thermal_out" ]]; then
    local cpu_temp
    cpu_temp=$(echo "$thermal_out" | awk '/CPU die temp/ {print $NF}' | tr -d 'C°')
    (( ${cpu_temp%.*} >= 90 )) 2>/dev/null && \
      _warn+=("CPU temp ${cpu_temp}°C — check fan and consider closing intensive workloads")
  fi

  # ── PRINT: action items first ─────────────────────────────────────────────
  printf "\n${BLD}── Action items${RST}\n"
  if (( ${#_crit[@]} + ${#_warn[@]} + ${#_info[@]} == 0 )); then
    printf "  ${GRN}${BLD}✓ All systems healthy${RST}\n"
  else
    for msg in "${_crit[@]}"; do
      printf "  ${RED}${BLD}[!]${RST} ${RED}%s${RST}\n" "$msg"
    done
    for msg in "${_warn[@]}"; do
      printf "  ${YLW}[!]${RST} ${YLW}%s${RST}\n" "$msg"
    done
    for msg in "${_info[@]}"; do
      printf "  ${DIM}[·] %s${RST}\n" "$msg"
    done
  fi

  # ── PRINT: CPU ────────────────────────────────────────────────────────────
  _header "CPU" "$(_pill "$cpu_label" $cpu_status)"
  printf "  ${DIM}%-18s${RST} " "load avg"
  (( load_int >= cores )) && printf "${YLW}%s${RST}" "$load1" || printf "${GRN}%s${RST}" "$load1"
  printf "  ${DIM}%s / %s  (1m / 5m / 15m  |  %s logical cores)${RST}\n" "$load5" "$load15" "$cores"
  printf "  ${DIM}%-18s${RST} user ${BLD}%s%%${RST}  sys ${BLD}%s%%${RST}  idle " "usage" "$user_pct" "$sys_pct"
  (( ${idle_pct%.*} >= 50 )) && printf "${GRN}%s%%${RST}\n" "$idle_pct" || printf "${YLW}%s%%${RST}\n" "$idle_pct"
  if (( load_int >= cores )) && (( ${idle_pct%.*} >= 40 )); then
    _hint "high load + high idle → memory pressure or I/O wait, not CPU bound"
  fi

  # ── PRINT: Memory ─────────────────────────────────────────────────────────
  _header "Memory" "$(_pill "$mem_label" $mem_status)"
  printf "  ${DIM}%-18s${RST} $(_bar $used_pct) " "physical"
  (( used_pct >= 90 )) \
    && printf "${RED}%sG / %sG (%d%%)${RST}\n" "$used_gb" "$total_gb" "$used_pct" \
    || printf "%sG / %sG (%d%%)\n" "$used_gb" "$total_gb" "$used_pct"
  printf "  ${DIM}%-18s${RST} free ${BLD}%sGB${RST}  active ${BLD}%sGB${RST}  inactive ${BLD}%sGB${RST}  wired ${BLD}%sGB${RST}\n" \
    "" "$free_gb" "$active_gb" "$inactive_gb" "$wired_gb"
  if (( comp_int > 2 )); then
    printf "  ${DIM}%-18s${RST} ${YLW}%sGB${RST}  ${DIM}(compressing pages to avoid swap — CPU overhead)${RST}\n" "compressor" "$comp_gb"
  else
    printf "  ${DIM}%-18s${RST} %sGB\n" "compressor" "$comp_gb"
  fi

  # ── PRINT: Disk ───────────────────────────────────────────────────────────
  _header "Disk" ""
  echo "$disk_out" | awk '{
    pct=$5; gsub(/%/,"",pct)
    status = (pct+0 >= 90) ? "CRIT" : (pct+0 >= 75) ? "WARN" : "OK"
    printf "  \033[2m%-18s\033[0m %s / %s (%s%%)", $6, $3, $2, pct
    if      (status == "CRIT") printf "  \033[0;31m[✖ full]\033[0m"
    else if (status == "WARN") printf "  \033[0;33m[⚠ getting full]\033[0m"
    else                       printf "  \033[0;32m[✓ ok]\033[0m"
    print ""
  }'

  # ── PRINT: Top Processes ──────────────────────────────────────────────────
  _header "Top processes" "  ${DIM}(by CPU)${RST}"
  printf "  ${DIM}%-22s %6s %6s${RST}\n" "process" "%cpu" "%mem"
  echo "$ps_out" | awk 'NR>1 && NR<=8 {
    name = $11
    if (name ~ /\.app\//) {
      n = split(name, parts, "/")
      for (i=1;i<=n;i++) {
        if (parts[i] ~ /\.app$/) { gsub(/\.app$/,"",parts[i]); name=parts[i]; break }
      }
    } else {
      n = split(name, parts, "/"); name = parts[n]
    }
    cpuint = int($3+0)
    if      (cpuint >= 30) cpucol="\033[0;31m"
    else if (cpuint >= 10) cpucol="\033[0;33m"
    else                   cpucol="\033[0m"
    printf "  \033[2m%-22s\033[0m %s%6s\033[0m %6s\n", name, cpucol, $3"%", $4"%"
  }'

  # ── PRINT: Network ────────────────────────────────────────────────────────
  _header "Network" ""
  ifconfig 2>/dev/null | awk '
    /^[a-z]/ { iface=$1; gsub(/:$/,"",iface) }
    /inet [0-9]/ {
      type = "LAN"
      if (iface ~ /^lo/)   type = "loopback"
      if (iface ~ /^utun/) type = "VPN/tunnel"
      if (iface ~ /^en1/)  type = "WiFi"
      if (iface ~ /^en0/)  type = "Ethernet/WiFi"
      printf "  \033[2m%-10s\033[0m %-18s \033[2m%s\033[0m\n", iface, $2, type
    }
  '

  # ── PRINT: File Descriptors ───────────────────────────────────────────────
  _header "Open file descriptors" "$(_pill "$fd_label" $fd_status)"
  printf "  ${DIM}%-18s${RST} %s  ${DIM}(typical: 5k–25k)${RST}\n" \
    "total" "$(printf "%'d" $fd_count)"

  # ── PRINT: Thermals ───────────────────────────────────────────────────────
  if [[ -n "$thermal_out" ]]; then
    _header "Thermals" ""
    echo "$thermal_out" | awk '
      /CPU die temp/     { printf "  \033[2m%-18s\033[0m %s\n",     "cpu temp", $NF }
      /Fan [0-9]+ speed/ { printf "  \033[2m%-18s\033[0m %s RPM\n", "fan " $2, $NF }
    '
  fi

  printf "\n"
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

[[ -f ~/scripts/ollm.zsh ]] && source ~/scripts/ollm.zsh

# ============================================
# DOTFILES MANAGEMENT
# ============================================
export DOTFILES="$HOME/dev/dotfiles"
alias dotfiles="$DOTFILES/scripts/sync-dotfiles.sh"
alias dotbackup="$DOTFILES/scripts/sync-dotfiles.sh push"
alias dotrestore="$DOTFILES/scripts/sync-dotfiles.sh restore"
alias dotstatus="$DOTFILES/scripts/sync-dotfiles.sh status"
alias dottest="$DOTFILES/scripts/test-dotfiles-setup.sh"
alias dothelp="$DOTFILES/scripts/dothelp.sh"

# Added by cua-driver-rs installer — see https://github.com/trycua/cua
export PATH="/Users/pieterdejong/.local/bin:$PATH"
