#!/usr/bin/env bash
# =============================================================================
#  mc-setup.sh - One-shot installer for a Minecraft Java Edition server
#
#  Tested target: Ubuntu 22.04 / 24.04 (x86_64 or ARM64), home PC or VPS.
#  Usage:         sudo bash mc-setup.sh              (install, or change settings)
#                 sudo bash mc-setup.sh --uninstall
#
#  What it does:
#    1. Asks a few questions (server type, version, game mode, whitelist, network)
#    2. Installs the right Java for your Minecraft version
#    3. Creates a locked-down "minecraft" user and downloads the server as that user
#       (Paper, Vanilla or Fabric), optionally with Bedrock crossplay (Geyser)
#    4. Writes server.properties, a systemd service (auto-start + auto-restart,
#       saves the world on shutdown) and a daily backup timer
#    5. Configures the firewall (Tailscale-only, public, or LAN-only)
#    6. Installs the 'mcserver' command: interactive menu, whitelist, plugins/mods
#       from Modrinth, backups, updates, logs, console  (run 'mcserver' after setup)
#
#  Safe to re-run: it backs up the world first and keeps it.
#  Full log: /var/log/mc-setup.log
# =============================================================================
set -uo pipefail

SRV_USER=minecraft
SRV_HOME=/home/$SRV_USER
INSTALL_DIR=$SRV_HOME/server
ENV_FILE=/etc/mcserver.env
PROPS=$INSTALL_DIR/server.properties
GAME_PORT=25565
BEDROCK_PORT=19132
RCON_PORT=25575
LOG=/var/log/mc-setup.log
INFO_FILE=$SRV_HOME/SERVER-INFO.txt
HELPER=/usr/local/bin/mcserver
STOP_SCRIPT=/usr/local/lib/mcserver/stop.sh
TITLE="Minecraft Server Setup"
APT="apt-get -y -o DPkg::Lock::Timeout=600"
# Aikar's G1 flags (the standard tuning for Minecraft servers). IgnoreUnrecognizedVMOptions
# keeps the server starting even if a future Java drops one of them.
JVM_FLAGS="-XX:+IgnoreUnrecognizedVMOptions -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1"

# ---------------------------------------------------------------- pre-checks
if [[ $EUID -ne 0 ]]; then
  echo "This script needs root. Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *ubuntu* ]]; then
  echo "Sorry, this script only supports Ubuntu (detected: ${PRETTY_NAME:-unknown})."
  exit 1
fi
case "$(uname -m)" in
  x86_64|aarch64) ;;
  *) echo "Sorry, only 64-bit Intel/AMD or ARM machines are supported. Detected: $(uname -m)."; exit 1 ;;
esac

if ! command -v whiptail >/dev/null 2>&1; then
  echo "Installing whiptail for the setup screens..."
  apt-get update -qq && $APT -qq install whiptail >/dev/null || { echo "Could not install whiptail."; exit 1; }
fi

cd /tmp || exit 1   # minecraft user can't read /root; avoid cwd errors in sudo -u commands
FAIL_FILE=$(mktemp)
trap 'rm -f "$FAIL_FILE"' EXIT
echo "=== Minecraft setup started $(date) ===" >>"$LOG"
chmod 600 "$LOG"   # the log records the RCON password
rm -f "$LOG.warnings"

# ---------------------------------------------------------------- UI helpers
cancelled() {
  whiptail --title "$TITLE" --msgbox "Setup cancelled. Nothing was changed." 8 50
  exit 0
}
ask_input() { whiptail --title "$TITLE" --inputbox "$1" 13 76 "$2" 3>&1 1>&2 2>&3; }
prev()      { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -1; }   # value from a previous install
prop()      { sed -n "s/^$1=//p" "$PROPS" 2>/dev/null | head -1; }
clean()     { tr -d '\\\r\n' <<<"$1"; }   # strip characters that would break server.properties
valid_names() {   # keeps valid Java usernames, reports the rest
  local n ok=() bad=()
  for n in $1; do
    if [[ "$n" =~ ^[A-Za-z0-9_]{1,16}$ ]]; then ok+=("$n"); else bad+=("$n"); fi
  done
  (( ${#bad[@]} )) && whiptail --title "$TITLE" --msgbox \
    "Skipping invalid Minecraft usernames: ${bad[*]}\n(Letters, numbers and _ only, max 16.)" 10 70 >/dev/tty
  echo "${ok[*]:-}"
}

# ---------------------------------------------------------------- uninstall
if [[ "${1:-}" == "--uninstall" ]]; then
  whiptail --title "$TITLE" --yesno "Remove the Minecraft server service, the 'mcserver' command and its firewall rules?

Your world and backups in $SRV_HOME are kept unless you choose to delete them next." 12 72 || cancelled
  systemctl disable --now mcserver-backup.timer mcserver >/dev/null 2>&1
  rm -f /etc/systemd/system/mcserver.service /etc/systemd/system/mcserver-backup.service \
        /etc/systemd/system/mcserver-backup.timer "$HELPER" "$ENV_FILE"
  rm -rf /usr/local/lib/mcserver
  systemctl daemon-reload
  if command -v ufw >/dev/null 2>&1; then
    for rule in "$GAME_PORT/tcp" "$BEDROCK_PORT/udp"; do
      ufw delete allow "$rule" >/dev/null 2>&1
      ufw delete allow in on tailscale0 to any port "${rule%/*}" proto "${rule#*/}" >/dev/null 2>&1
      for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        ufw delete allow from "$net" to any port "${rule%/*}" proto "${rule#*/}" >/dev/null 2>&1
      done
    done
  fi
  msg="The server is uninstalled."
  if id "$SRV_USER" >/dev/null 2>&1; then
    if whiptail --title "$TITLE" --defaultno --yesno "Also DELETE the world, settings and all backups in $SRV_HOME?

This can't be undone." 11 70 \
       && whiptail --title "$TITLE" --defaultno --yesno "Really delete everything in $SRV_HOME?" 8 60; then
      pkill -u "$SRV_USER" >/dev/null 2>&1; sleep 2; pkill -9 -u "$SRV_USER" >/dev/null 2>&1
      if userdel -r "$SRV_USER" >/dev/null 2>&1; then
        msg="The server, world and backups are removed."
      else
        msg="The server is uninstalled, but $SRV_HOME could not be deleted. Remove it with:
  sudo userdel -r $SRV_USER"
      fi
    else
      msg="The server is uninstalled. Your world and backups are still in $SRV_HOME."
    fi
  fi
  whiptail --title "$TITLE" --msgbox "$msg

Java and Tailscale were left installed. To remove them:
  sudo apt remove 'openjdk-*-jre-headless' 'temurin-*' tailscale" 12 74
  exit 0
fi

# ---------------------------------------------------------------- questions
EXISTING=0
[[ -d "$INSTALL_DIR" && -f "$PROPS" ]] && EXISTING=1
LEVEL=$(prop level-name); LEVEL=${LEVEL:-world}
HAS_WORLD=0
[[ -d "$INSTALL_DIR/$LEVEL" ]] && HAS_WORLD=1

whiptail --title "$TITLE" --yesno \
"This will set up a Minecraft Java Edition server on this machine.

It will:
  - install Java and download the server (a few hundred MB)
  - create a separate '$SRV_USER' user to run the server safely
  - set it to start automatically, restart if it crashes,
    and back up the world every day
  - configure the firewall
$( ((EXISTING)) && echo "
An existing server was found. Your world is kept and backed up first.")
You'll answer a few questions first. Continue?" 21 72 || cancelled

avail_gb=$(df -BG --output=avail /home | tail -1 | tr -dc '0-9')
if (( avail_gb < 5 )); then
  whiptail --title "$TITLE" --yesno \
"Only ${avail_gb} GB of free disk space on /home.
The server needs a few GB, and worlds and backups grow over time.

Continue anyway?" 11 64 || cancelled
fi

whiptail --title "$TITLE" --yesno \
"Minecraft servers require you to accept Mojang's End User License
Agreement (EULA):

  https://aka.ms/MinecraftEULA

In short: you can run a server for free, but you can't sell
gameplay advantages or charge for access beyond what the EULA allows.

Do you accept the Minecraft EULA?" 16 72 || cancelled

P_TYPE=$(prev MC_TYPE)
MC_TYPE=$(whiptail --title "$TITLE" --default-item "${P_TYPE:-paper}" --menu \
"Server software:

Paper is the usual choice: same gameplay, runs much faster, and
supports plugins. Pick Fabric if you want to install mods." 17 76 3 \
  "paper"   "Paper - fast, supports plugins (recommended)" \
  "vanilla" "Vanilla - the official Mojang server, no add-ons" \
  "fabric"  "Fabric - supports mods (e.g. Lithium, Create)" 3>&1 1>&2 2>&3) || cancelled

P_VER=$(prev MC_VERSION)
if [[ -n "$P_VER" && "$P_TYPE" == "$MC_TYPE" ]]; then
  VER_HINT="Your world is on $P_VER. Keep it, or type a newer version / 'latest'
to upgrade (upgrades can't be undone - a backup is made first)."
  VER_DEFAULT=$P_VER
else
  VER_HINT="'latest' picks the newest release that $MC_TYPE supports.
Everyone who joins needs the same Minecraft version."
  VER_DEFAULT=latest
fi
MC_VER=$(ask_input "Minecraft version ('latest' or a number like 26.3):

$VER_HINT" "$VER_DEFAULT") || cancelled
MC_VER=$(tr -d ' ' <<<"$MC_VER"); MC_VER=${MC_VER:-latest}
if [[ ! "$MC_VER" =~ ^(latest|[0-9]+(\.[0-9]+)+)$ ]]; then
  whiptail --title "$TITLE" --msgbox "'$MC_VER' doesn't look like a release version. Using 'latest'." 8 64
  MC_VER=latest
fi

P_MOTD=$(prop motd)
MOTD=$(ask_input "Server name (shown in the multiplayer server list):" "${P_MOTD:-My Minecraft Server}") || cancelled
MOTD=$(clean "$MOTD"); [[ -z "$MOTD" ]] && MOTD="My Minecraft Server"

P_MODE=$(prop gamemode); [[ "$(prop hardcore)" == "true" ]] && P_MODE=hardcore
GAMEMODE=$(whiptail --title "$TITLE" --default-item "${P_MODE:-survival}" --menu "Game mode:" 14 64 4 \
  "survival"  "Survival - gather, build, survive" \
  "creative"  "Creative - unlimited blocks, flying" \
  "adventure" "Adventure - for custom maps" \
  "hardcore"  "Hardcore - survival on hard, one life" 3>&1 1>&2 2>&3) || cancelled

DIFFICULTY=hard
if [[ "$GAMEMODE" != "hardcore" ]]; then
  P_DIFF=$(prop difficulty)
  DIFFICULTY=$(whiptail --title "$TITLE" --default-item "${P_DIFF:-normal}" --menu "Difficulty:" 14 50 4 \
    "peaceful" "No hostile mobs" "easy" "" "normal" "" "hard" "" 3>&1 1>&2 2>&3) || cancelled
fi

P_MAX=$(prop max-players)
while :; do
  MAX_PLAYERS=$(ask_input "Maximum players online at once:" "${P_MAX:-10}") || cancelled
  [[ "$MAX_PLAYERS" =~ ^[0-9]+$ ]] && (( MAX_PLAYERS >= 1 && MAX_PLAYERS <= 500 )) && break
  whiptail --title "$TITLE" --msgbox "Please enter a number from 1 to 500." 8 50
done

SEED=""
if (( ! HAS_WORLD )); then
  SEED=$(ask_input "World seed (optional).

Leave blank for a random world, or paste a seed you like." "") || cancelled
  SEED=$(clean "$SEED")
fi

# Memory: leave about 1 GB for the operating system
total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
max_gb=$(( (total_mb - 700) / 1024 )); (( max_gb < 1 )) && max_gb=1
rec_gb=$(( (total_mb - 1024) / 1024 )); (( rec_gb < 1 )) && rec_gb=1; (( rec_gb > 8 )) && rec_gb=8
RAM_ITEMS=()
for g in 1 2 3 4 5 6 8 10 12 16 24 32; do
  (( g > max_gb )) && break
  (( g <= rec_gb )) && rec_pick=$g
  RAM_ITEMS+=("${g}G" "$( ((g == 1)) && echo "tight - 1-2 players, no mods")")
done
P_RAM=$(prev MC_RAM)
MC_RAM=$(whiptail --title "$TITLE" --default-item "${P_RAM:-${rec_pick:-1}G}" --menu \
"Memory for the server (this machine has $(( (total_mb + 512) / 1024 )) GB).

Rough guide: 2-3G for a few friends, 4-6G for 10+ players
or a modpack. Leave ~1 GB for the system. Change later: mcserver ram" 20 72 8 \
  "${RAM_ITEMS[@]}" 3>&1 1>&2 2>&3) || cancelled
(( total_mb < 1800 )) && whiptail --title "$TITLE" --msgbox \
  "This machine has under 2 GB of RAM. The server will run, but expect lag with more than a couple of players." 9 70

OWNER=""; FRIENDS=""; WHITELIST=true
P_WL=$(prop white-list)
WL_OPT=(); [[ "$P_WL" == "false" ]] && WL_OPT=(--defaultno)
if ! whiptail --title "$TITLE" "${WL_OPT[@]}" --yesno \
"Use a whitelist? (recommended)

Only players you add can join. Without it, anyone who finds
your server's address can join and grief your builds.
Add more players later with:  mcserver whitelist add <name>" 13 70; then
  WHITELIST=false
fi
while :; do
  OWNER=$(ask_input "YOUR Minecraft Java username.

You'll be made an operator (admin) and added to the whitelist.
$( [[ $WHITELIST == false ]] && echo "Leave blank to skip." )" "") || cancelled
  OWNER=$(valid_names "$(clean "$OWNER")"); OWNER=${OWNER%% *}
  [[ -n "$OWNER" || $WHITELIST == false ]] && break
  whiptail --title "$TITLE" --msgbox "With the whitelist on, enter your username so you can join." 8 64
done
if [[ $WHITELIST == true ]]; then
  FRIENDS=$(ask_input "Friends' Minecraft Java usernames to allow (optional).

Separate them with spaces. You can add more any time later." "") || cancelled
  FRIENDS=$(valid_names "$(clean "$FRIENDS")")
fi

BEDROCK=0
if [[ "$MC_TYPE" == "paper" ]]; then
  P_BR=$(prev MC_BEDROCK)
  BR_OPT=(--defaultno); [[ "$P_BR" == "1" ]] && BR_OPT=()
  whiptail --title "$TITLE" "${BR_OPT[@]}" --yesno \
"Let Bedrock players join too? (phone, tablet, console, Windows Bedrock)

This installs Geyser + Floodgate, free plugins that translate between
Bedrock and Java, so Bedrock friends can play without a Java account.
Most things work the same; a few Java-only features differ." 14 76 && BEDROCK=1
fi

NET_MODE=$(whiptail --title "$TITLE" --default-item "$(prev MC_NET)" --menu \
"How should friends reach the server?

Tailscale is the safest: nothing is exposed to the internet, and it
works even if your ISP uses CGNAT (common in the Philippines).
Everyone installs the free Tailscale app (PC, Android, iPhone)." 19 78 3 \
  "tailscale" "Friends only, via Tailscale (recommended)" \
  "public"    "Open to the internet (VPS, or home + port forward)" \
  "lan"       "Local network only (same Wi-Fi / router)" 3>&1 1>&2 2>&3) || cancelled

if [[ "$NET_MODE" == "public" && $WHITELIST == false ]]; then
  whiptail --title "$TITLE" --yesno "Public server without a whitelist:

Bots constantly scan the internet for open Minecraft servers.
Expect strangers to join and grief. Continue anyway?" 12 68 || cancelled
fi
if [[ "$NET_MODE" == "tailscale" && $BEDROCK == 1 ]]; then
  whiptail --title "$TITLE" --msgbox "Note: consoles (Xbox, PlayStation, Switch) can't run Tailscale,
so with Tailscale only phones, tablets and PCs can join as Bedrock players.
Pick 'public' instead if console friends need to join." 11 74
fi

whiptail --title "$TITLE" --yesno \
"Please confirm:

  Software    : $MC_TYPE $MC_VER
  Server name : $MOTD
  Game mode   : $GAMEMODE / $DIFFICULTY
  Max players : $MAX_PLAYERS
  Memory      : $MC_RAM
  Whitelist   : $WHITELIST$( [[ -n "$OWNER" ]] && echo " (owner: $OWNER)")
  Friends     : ${FRIENDS:-(none yet)}
  Bedrock     : $( ((BEDROCK)) && echo "yes (port $BEDROCK_PORT/udp)" || echo no)
  Network     : $NET_MODE
  Port        : $GAME_PORT/tcp
$( [[ -n "$P_TYPE" && "$P_TYPE" != "$MC_TYPE" ]] && echo "
Switching from $P_TYPE to $MC_TYPE. Your world is backed up first.")
Start installing now?" 23 76 || cancelled

# ---------------------------------------------------------------- install steps
progress() { printf 'XXX\n%d\n%b\nXXX\n' "$1" "$2"; }
run()      { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }
fail()     { echo "$1" >"$FAIL_FILE"; exit 1; }
last_line(){ tail -n 1 "$1" 2>/dev/null | tr -d '\r' | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-70; }

# A broken third-party repo (e.g. an old PPA) makes 'apt-get update' exit non-zero even
# though Ubuntu's own repos updated fine. Warn instead of aborting; if a package we need
# really can't be found, the install step right after will fail with a clear message.
apt_update() {
  if ! run apt-get update; then
    echo "WARNING: apt-get update reported errors (often an unrelated broken repo). Continuing." >>"$LOG"
    grep -E '^(E|W): ' "$LOG" | tail -n 3 >>"$LOG.warnings" 2>/dev/null || true
  fi
}

# Add Tailscale's apt repo ourselves (what their install.sh does) so our tolerant
# apt_update is used - their script aborts if ANY unrelated repo on the system is broken.
install_tailscale() {
  local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  if [[ -n "$codename" ]] \
     && run curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
            -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
     && run curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
            -o /etc/apt/sources.list.d/tailscale.list; then
    chmod 644 /usr/share/keyrings/tailscale-archive-keyring.gpg /etc/apt/sources.list.d/tailscale.list
    apt_update
    if run $APT install tailscale; then
      run systemctl enable --now tailscaled
      return 0
    fi
  fi
  echo "Direct Tailscale install failed; trying the official install script..." >>"$LOG"
  run sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'
}

# Runs a command in the background, showing its latest log line in the progress bar
run_watched() {   # $1 = percent, $2 = message, rest = command
  local pct=$1 msg=$2 pid
  shift 2
  echo "+ $*" >>"$LOG"
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    progress "$pct" "$msg\n\n$(last_line "$LOG")"
    sleep 2
  done
  wait "$pid"
}

install_all() {
  progress 2 "Updating package lists..."
  apt_update

  progress 5 "Installing base packages..."
  DEBIAN_FRONTEND=noninteractive run $APT install ca-certificates curl ufw tmux python3 gnupg whiptail \
    || fail "Could not install base packages."

  progress 10 "Creating the '$SRV_USER' user..."
  if ! id "$SRV_USER" >/dev/null 2>&1; then
    run useradd -m -s /bin/bash "$SRV_USER" || fail "Could not create user $SRV_USER."
  fi
  chmod 750 "$SRV_HOME"
  run install -d -o "$SRV_USER" -g "$SRV_USER" "$INSTALL_DIR"

  progress 12 "Installing the 'mcserver' helper command..."
  write_helper

  if systemctl is-active --quiet mcserver 2>/dev/null || [[ -d "$INSTALL_DIR/$LEVEL" ]]; then
    progress 14 "Backing up your existing world before changing anything..."
    run "$HELPER" backup || fail "Could not back up the existing world, so nothing was changed."
    progress 16 "Stopping the server..."
    run systemctl stop mcserver
  fi

  run_watched 20 "Installing Java and downloading the $MC_TYPE server.\nThis can take a few minutes..." \
    "$HELPER" _install --type "$MC_TYPE" --version "$MC_VER" \
    || fail "Could not install the server. The log below says why (often a version that doesn't exist for $MC_TYPE)."

  progress 60 "Writing server.properties..."
  printf '# Accepted in mc-setup.sh on %s (https://aka.ms/MinecraftEULA)\neula=true\n' "$(date)" >"$INSTALL_DIR/eula.txt"
  chown "$SRV_USER:$SRV_USER" "$INSTALL_DIR/eula.txt"
  local rcon_pass hc=false gm=$GAMEMODE extra=()
  rcon_pass=$(prop rcon.password)
  [[ -z "$rcon_pass" ]] && rcon_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  [[ "$GAMEMODE" == "hardcore" ]] && { hc=true; gm=survival; }
  (( ! EXISTING )) && extra+=("spawn-protection=0")      # friends can build near spawn
  [[ -n "$SEED" ]] && extra+=("level-seed=$SEED")
  run "$HELPER" _props "motd=$MOTD" "gamemode=$gm" "hardcore=$hc" "difficulty=$DIFFICULTY" \
    "max-players=$MAX_PLAYERS" "white-list=$WHITELIST" "enforce-whitelist=$WHITELIST" \
    "online-mode=true" "server-port=$GAME_PORT" "enable-rcon=true" "rcon.port=$RCON_PORT" \
    "rcon.password=$rcon_pass" "broadcast-rcon-to-ops=false" "${extra[@]}" \
    || fail "Could not write server.properties."

  progress 64 "Creating the systemd service (auto-start on boot, daily backups)..."
  write_services
  run systemctl daemon-reload

  if [[ "$NET_MODE" == "tailscale" ]] && ! command -v tailscale >/dev/null 2>&1; then
    progress 70 "Installing Tailscale..."
    install_tailscale || fail "Could not install Tailscale."
  fi

  progress 76 "Configuring the firewall..."
  run "$HELPER" _firewall || fail "Firewall configuration failed."

  progress 80 "Starting the server..."
  run systemctl enable mcserver mcserver-backup.timer
  run systemctl start mcserver-backup.timer
  local started i mclog=$INSTALL_DIR/logs/latest.log
  started=$(date +%s)
  run systemctl restart mcserver
  # The first start generates the world, which takes a while (longer on small/ARM machines)
  local seen_java=0
  for i in $(seq 1 300); do
    if [[ -f "$mclog" ]] && (( $(stat -c %Y "$mclog") >= started )); then
      grep -q 'Done (' "$mclog" && break
      if grep -qE 'UnsupportedClassVersionError|Failed to start the minecraft server|FAILED TO BIND' "$mclog"; then
        fail "The server stopped with an error. Check: $mclog"
      fi
    fi
    pgrep -u "$SRV_USER" -x java >/dev/null && seen_java=$i
    if (( i - seen_java > 30 )); then   # no Java process for a minute: it's crashing on start
      fail "The server keeps exiting right after it starts. To see the error, run it by hand:
  cd $INSTALL_DIR && sudo -u $SRV_USER $(prev MC_JAVA) -jar $(prev MC_JAR) nogui"
    fi
    systemctl is-failed --quiet mcserver && fail "The server service failed. Check: journalctl -u mcserver"
    progress $(( 80 + i * 15 / 300 )) "Starting the server and generating the world...\n(the first start takes a few minutes)\n\n$(last_line "$mclog")"
    sleep 2
  done
  grep -q 'Done (' "$mclog" 2>/dev/null || fail "The server didn't finish starting in 10 minutes. Check: $mclog"
  run "$HELPER" _wait 60 || fail "The server started but its remote console (RCON) isn't answering. Check: $mclog"

  progress 96 "Adding players..."
  if [[ -n "$OWNER" ]]; then
    [[ $WHITELIST == true ]] && { run "$HELPER" whitelist add "$OWNER" || echo "Could not whitelist $OWNER" >>"$LOG.players"; }
    run "$HELPER" op "$OWNER" || echo "Could not make $OWNER an operator" >>"$LOG.players"
  fi
  if [[ -n "$FRIENDS" ]]; then
    # shellcheck disable=SC2086
    run "$HELPER" whitelist add $FRIENDS || echo "Some friends could not be whitelisted" >>"$LOG.players"
  fi

  progress 100 "Done!"
  sleep 1
}

write_services() {
  install -d /usr/local/lib/mcserver
  cat >"$STOP_SCRIPT" <<'EOF'
#!/bin/sh
# Ask Minecraft to save the world and shut down cleanly, then wait for it to exit.
tmux has-session -t mc 2>/dev/null || exit 0
tmux send-keys -t mc C-u
tmux send-keys -t mc "stop" Enter
i=0
while tmux has-session -t mc 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 110 ]; then tmux kill-session -t mc; exit 0; fi
  sleep 1
done
EOF
  chmod 755 "$STOP_SCRIPT"

  cat >/etc/systemd/system/mcserver.service <<EOF
[Unit]
Description=Minecraft Server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=$SRV_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStartPre=-/usr/bin/tmux kill-session -t mc
ExecStart=/usr/bin/tmux new-session -d -s mc "\${MC_JAVA} -Xms\${MC_RAM} -Xmx\${MC_RAM} \${MC_JVM_FLAGS} -jar \${MC_JAR} nogui"
ExecStop=$STOP_SCRIPT
TimeoutStopSec=120
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/mcserver-backup.service <<EOF
[Unit]
Description=Minecraft world backup

[Service]
Type=oneshot
ExecStart=$HELPER backup --auto
EOF

  cat >/etc/systemd/system/mcserver-backup.timer <<EOF
[Unit]
Description=Daily Minecraft world backup

[Timer]
OnCalendar=*-*-* 05:00:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_helper() {
  # Settings shared by the systemd service and the mcserver command.
  # MC_TYPE/MC_VERSION/MC_JAVA/MC_JAR are filled in by 'mcserver _install'.
  local keep=""
  for k in MC_TYPE MC_VERSION MC_BUILD MC_JAVA MC_JAR MC_JAVA_MAJOR MC_NOTE; do
    [[ -n "$(prev $k)" ]] && keep+="$k=$(prev $k)"$'\n'
  done
  cat >"$ENV_FILE" <<EOF
MC_USER=$SRV_USER
MC_HOME=$SRV_HOME
MC_DIR=$INSTALL_DIR
MC_PORT=$GAME_PORT
MC_RAM=$MC_RAM
MC_NET=$NET_MODE
MC_BEDROCK=$BEDROCK
MC_BACKUP_KEEP=$(prev MC_BACKUP_KEEP | grep -E '^[0-9]+$' || echo 7)
MC_JVM_FLAGS=$JVM_FLAGS
${keep}
EOF
  chmod 644 "$ENV_FILE"

  cat >"$HELPER" <<'MC_HELPER_EOF'
#!/usr/bin/env python3
# =============================================================================
#  mcserver - manage the Minecraft server (installed by mc-setup.sh)
#
#  Run "mcserver" or "mcserver menu" for the interactive menu, "mcserver help" for commands.
#  Settings shared with the systemd service live in /etc/mcserver.env
# =============================================================================
import glob
import hashlib
import json
import os
import pwd
import re
import shutil
import socket
import struct
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

ENV_FILE = "/etc/mcserver.env"
UA = {"User-Agent": "mcserver-helper/1.0 (https://github.com/helloworld0123)"}
MOJANG_MANIFEST = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
PAPER_API = "https://fill.papermc.io/v3/projects/paper"
FABRIC_API = "https://meta.fabricmc.net/v2/versions"
GEYSER_DL = "https://download.geysermc.org/v2/projects/{}/versions/latest/builds/latest/downloads/spigot"
GEYSER_JARS = (("geyser", "Geyser-Spigot.jar"), ("floodgate", "floodgate-spigot.jar"))
MODRINTH = "https://api.modrinth.com/v2"
ADOPTIUM_KEY = "https://packages.adoptium.net/artifactory/api/gpg/key/public"
ADOPTIUM_REPO = "https://packages.adoptium.net/artifactory/deb"
SESSION = "mc"
SERVICE = "mcserver"
WT_TITLE = "Minecraft Server"
BEDROCK_PORT = 19132
PRIVATE_NETS = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
NAME_RE = re.compile(r"^[A-Za-z0-9_]{1,16}$")            # Java Edition usernames
GAMERTAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ]{0,15}$")  # Xbox gamertags (Bedrock)
RAM_RE = re.compile(r"^([1-9][0-9]{0,2})([GM])$")
COLOR_RE = re.compile(r"§.")
# Top-level entries that are downloaded/regenerated, so backups skip them
BACKUP_SKIP = {"libraries", "versions", "cache", "logs", "crash-reports", "debug", ".fabric"}


class UserError(Exception):
    """A problem to show the user as a plain message, without a traceback."""


# ----------------------------------------------------------------- settings
def load_env(path=None):
    path = path or ENV_FILE
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"')
    return env


def set_env(key, value):
    with open(ENV_FILE) as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith(key + "="):
            lines[i] = f"{key}={value}"
            break
    else:
        lines.append(f"{key}={value}")
    with open(ENV_FILE, "w") as f:
        f.write("\n".join(lines) + "\n")
    ENV[key] = value


ENV = {}
USER = HOME = DIR = PROPS = LOGFILE = BACKUPS = INDEX = INFO = ""


def init_paths():
    global ENV, USER, HOME, DIR, PROPS, LOGFILE, BACKUPS, INDEX, INFO
    ENV = load_env()
    USER = ENV.get("MC_USER", "minecraft")
    HOME = ENV.get("MC_HOME", f"/home/{USER}")
    DIR = ENV.get("MC_DIR", f"{HOME}/server")
    PROPS = os.path.join(DIR, "server.properties")
    LOGFILE = os.path.join(DIR, "logs", "latest.log")
    BACKUPS = os.path.join(HOME, "backups")
    INDEX = os.path.join(HOME, "addons.json")
    INFO = os.path.join(HOME, "SERVER-INFO.txt")


# ----------------------------------------------------------------- small helpers
def die(msg):
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit in ("B", "KB") else f"{n:.1f} {unit}"
        n /= 1024


def as_user(cmd):
    return ["sudo", "-u", USER, "-H"] + cmd


def chown_user(path):
    pw = pwd.getpwnam(USER)
    os.chown(path, pw.pw_uid, pw.pw_gid)


def chown_tree(path):
    pw = pwd.getpwnam(USER)
    for root, dirs, files in os.walk(path):
        for n in dirs + files:
            try:
                os.lchown(os.path.join(root, n), pw.pw_uid, pw.pw_gid)
            except OSError:
                pass
    os.lchown(path, pw.pw_uid, pw.pw_gid)


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path, exist_ok=True)
        chown_user(path)
    return path


def ask_yes(prompt):
    if not sys.stdin.isatty():
        return False
    return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")


def vkey(v):
    """'26.1.2' -> (26, 1, 2). None for snapshots, pre-releases and other odd names."""
    return tuple(int(x) for x in v.split(".")) if re.fullmatch(r"\d+(\.\d+)*", v or "") else None


def type_label(kind):
    return {"paper": "Paper", "vanilla": "Vanilla", "fabric": "Fabric"}.get(kind, kind)


def addon_dir():
    kind = ENV.get("MC_TYPE")
    if kind == "paper":
        return os.path.join(DIR, "plugins")
    if kind == "fabric":
        return os.path.join(DIR, "mods")
    raise UserError("Vanilla servers can't load plugins or mods.\n"
                    "Re-run mc-setup.sh and pick Paper (plugins) or Fabric (mods). Your world is kept.")


# ----------------------------------------------------------------- downloads
def fetch(url, timeout=60):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=timeout) as r:
        return r.read()


def fetch_json(url):
    return json.loads(fetch(url, 30))


def download(url, dest, hashes=None, quiet=False):
    """Download url to dest atomically. hashes: optional {"sha1"|"sha256"|"sha512": hexdigest}."""
    tmp = dest + ".part"
    hs = {k: hashlib.new(k) for k in (hashes or {})}
    got, last = 0, 0.0
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120) as r, open(tmp, "wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            while True:
                chunk = r.read(1 << 16)
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
                for h in hs.values():
                    h.update(chunk)
                if not quiet and sys.stdout.isatty() and time.time() - last > 0.3:
                    last = time.time()
                    pct = f" ({got * 100 // total}%)" if total else ""
                    print(f"\r  {os.path.basename(dest)}: {human(got)}{pct}   ", end="", flush=True)
        if not quiet and sys.stdout.isatty():
            print(f"\r  {os.path.basename(dest)}: {human(got)}          ")
        if got == 0:
            raise UserError(f"{url} returned an empty file.")
        for k, h in hs.items():
            if h.hexdigest().lower() != str(hashes[k]).lower():
                raise UserError(f"Checksum mismatch for {os.path.basename(dest)} - the download was damaged. Try again.")
        os.replace(tmp, dest)
        chown_user(dest)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return dest


def file_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# ----------------------------------------------------------------- versions
_manifest = None


def manifest():
    global _manifest
    if _manifest is None:
        _manifest = fetch_json(MOJANG_MANIFEST)
    return _manifest


def mojang_meta(version):
    for v in manifest()["versions"]:
        if v["id"] == version:
            return fetch_json(v["url"])
    raise UserError(f"Minecraft version '{version}' doesn't exist. Use a release like "
                    f"{manifest()['latest']['release']}, or 'latest'.")


def java_needed(meta):
    return int(meta.get("javaVersion", {}).get("majorVersion") or 21)


def paper_builds(version):
    try:
        data = fetch_json(f"{PAPER_API}/versions/{urllib.parse.quote(version)}/builds")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise
    if not isinstance(data, list):   # error object, e.g. {"ok": false, "message": ...}
        return []
    return sorted(data, key=lambda b: int(b.get("id") or 0), reverse=True)


def paper_is_stable(build):
    return str(build.get("channel", "")).upper() in ("STABLE", "RECOMMENDED")


def paper_versions():
    raw = fetch_json(PAPER_API).get("versions", {})
    groups = raw.values() if isinstance(raw, dict) else [raw]
    out = [v for group in groups for v in group if vkey(v)]
    return sorted(set(out), key=vkey, reverse=True)


def pick_paper(want):
    """Returns (version, build, note)."""
    if want != "latest":
        builds = paper_builds(want)
        if not builds:
            raise UserError(f"Paper has no builds for Minecraft {want} (yet). "
                            "Pick another version, or use Vanilla for brand-new releases.")
        stable = [b for b in builds if paper_is_stable(b)]
        note = "" if stable else f"Paper {want} only has experimental builds so far - expect bugs."
        return want, (stable or builds)[0], note
    newest = manifest()["latest"]["release"]
    for v in paper_versions()[:8]:
        stable = [b for b in paper_builds(v) if paper_is_stable(b)]
        if stable:
            note = "" if v == newest else (f"Paper doesn't have a stable build for {newest} yet, so this uses {v}. "
                                           "Run 'mcserver update --version latest' in a few weeks.")
            return v, stable[0], note
    raise UserError("Couldn't find a stable Paper build. Try a specific version, e.g. --version "
                    + newest)


def resolve(kind, want):
    """Work out exactly what to download for a server type and version ('latest' or e.g. '26.3').
    Returns a dict: version, url, hashes, jar, build, java, note."""
    want = (want or "latest").strip()
    newest = manifest()["latest"]["release"]
    if kind == "vanilla":
        version = newest if want == "latest" else want
        meta = mojang_meta(version)
        srv = meta.get("downloads", {}).get("server")
        if not srv:
            raise UserError(f"Minecraft {version} has no official server download.")
        return dict(version=version, url=srv["url"], hashes={"sha1": srv["sha1"]}, jar="server.jar",
                    build=f"Vanilla {version}", java=java_needed(meta), note="")
    if kind == "paper":
        version, build, note = pick_paper(want)
        dl = build["downloads"]["server:default"]
        sha = (dl.get("checksums") or {}).get("sha256")
        chan = "" if paper_is_stable(build) else f", {str(build.get('channel', '')).lower()}"
        return dict(version=version, url=dl["url"], hashes={"sha256": sha} if sha else {}, jar="server.jar",
                    build=f"Paper {version} build {build.get('id')}{chan}",
                    java=java_needed(mojang_meta(version)), note=note)
    if kind == "fabric":
        games = fetch_json(f"{FABRIC_API}/game")
        stable = [g["version"] for g in games if g.get("stable")]
        note = ""
        if want == "latest":
            version = newest if newest in stable else (stable[0] if stable else None)
            if not version:
                raise UserError("Fabric doesn't list any supported Minecraft versions right now.")
            if version != newest:
                note = f"Fabric doesn't support {newest} yet, so this uses {version}."
        else:
            if want not in (g["version"] for g in games):
                raise UserError(f"Fabric doesn't support Minecraft {want} (yet).")
            version = want
        loaders = fetch_json(f"{FABRIC_API}/loader")
        installers = fetch_json(f"{FABRIC_API}/installer")
        loader = next((x["version"] for x in loaders if x.get("stable")), loaders[0]["version"])
        installer = next((x["version"] for x in installers if x.get("stable")), installers[0]["version"])
        return dict(version=version, url=f"{FABRIC_API}/loader/{version}/{loader}/{installer}/server/jar",
                    hashes={}, jar="fabric-server.jar", build=f"Fabric {version} (loader {loader})",
                    java=java_needed(mojang_meta(version)), note=note)
    raise UserError(f"Unknown server type '{kind}' (use paper, vanilla or fabric).")


# ----------------------------------------------------------------- Java
def java_major_of(path):
    try:
        r = subprocess.run([path, "-version"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return 0
    m = re.search(r'version "(\d+)', r.stderr + r.stdout)
    return int(m.group(1)) if m else 0


def find_java(major):
    cands = sorted(set(glob.glob(f"/usr/lib/jvm/*-{major}-*/bin/java") + glob.glob(f"/usr/lib/jvm/*-{major}/bin/java")))
    for c in cands:
        if os.access(c, os.X_OK) and java_major_of(c) == major:
            return c
    return None


def apt(*args):
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    return subprocess.run(["apt-get", "-y", "-o", "DPkg::Lock::Timeout=600", *args], env=env).returncode == 0


def apt_install_any(pkgs):
    for pkg in pkgs:
        if apt("install", "--no-install-recommends", pkg):
            return True
    return False


def add_adoptium_repo():
    osr = load_env("/etc/os-release")
    codename = osr.get("UBUNTU_CODENAME") or osr.get("VERSION_CODENAME")
    if not codename:
        raise UserError("Couldn't work out the Ubuntu release name.")
    key = fetch(ADOPTIUM_KEY)
    r = subprocess.run(["gpg", "--batch", "--yes", "--dearmor", "-o", "/usr/share/keyrings/adoptium.gpg"], input=key)
    if r.returncode != 0:
        raise UserError("Couldn't import the Adoptium signing key.")
    with open("/etc/apt/sources.list.d/adoptium.list", "w") as f:
        f.write(f"deb [signed-by=/usr/share/keyrings/adoptium.gpg] {ADOPTIUM_REPO} {codename} main\n")
    apt("update")   # an unrelated broken repo makes this "fail"; the install below is what matters


def ensure_java(major):
    """Install Java <major> if needed and return the path to its java binary."""
    j = find_java(major)
    if j:
        return j
    print(f"Installing Java {major}...")
    pkgs = [f"openjdk-{major}-jre-headless"]
    if not apt_install_any(pkgs):
        apt("update")
        apt_install_any(pkgs)
    j = find_java(major)
    if j:
        return j
    print(f"Ubuntu doesn't offer Java {major}; adding the Eclipse Temurin (Adoptium) repository...")
    add_adoptium_repo()
    apt_install_any([f"temurin-{major}-jre", f"temurin-{major}-jdk"])
    j = find_java(major)
    if not j:
        raise UserError(f"Could not install Java {major}. Check your internet connection and try again.")
    return j


# ----------------------------------------------------------------- server.properties
def read_props():
    props = {}
    if os.path.exists(PROPS):
        with open(PROPS, encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith(("#", "!")) and "=" in s:
                    k, v = s.split("=", 1)
                    props[k.strip()] = v.strip()
    return props


def set_props(values):
    lines = []
    if os.path.exists(PROPS):
        with open(PROPS, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    done = set()
    for i, line in enumerate(lines):
        s = line.strip()
        if "=" in s and not s.startswith(("#", "!")):
            k = s.split("=", 1)[0].strip()
            if k in values:
                lines[i] = f"{k}={values[k]}"
                done.add(k)
    lines += [f"{k}={v}" for k, v in values.items() if k not in done]
    with open(PROPS, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    chown_user(PROPS)
    os.chmod(PROPS, 0o640)   # holds the RCON password


# ----------------------------------------------------------------- RCON
class Rcon:
    """Minimal Source RCON client, which is what Minecraft's remote console speaks."""

    def __init__(self, host, port, password, timeout=10):
        self.sock = socket.create_connection((host, port), timeout)
        self._send(3, password)
        rid, _ = self._recv()
        if rid == -1:
            self.close()
            raise UserError("the RCON password was rejected. Check rcon.password in server.properties.")
        self.sock.settimeout(120)   # 'save-all flush' on a big world can take a while

    def _send(self, typ, body):
        data = struct.pack("<ii", 1, typ) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(data)) + data)

    def _exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("RCON connection closed")
            buf += chunk
        return buf

    def _recv(self):
        n = struct.unpack("<i", self._exact(4))[0]
        data = self._exact(n)
        rid, _typ = struct.unpack("<ii", data[:8])
        return rid, data[8:-2].decode("utf-8", "replace")

    def cmd(self, command):
        self._send(2, command)
        return self._recv()[1]

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def rcon(*commands):
    """Run console commands on the running server. Returns the replies (colour codes removed)."""
    p = read_props()
    if p.get("enable-rcon") != "true" or not p.get("rcon.password"):
        raise UserError("remote console (RCON) is off in server.properties. Re-run mc-setup.sh to turn it back on.")
    try:
        r = Rcon("127.0.0.1", int(p.get("rcon.port") or 25575), p["rcon.password"])
    except OSError:
        raise UserError("the server isn't ready - it's stopped or still starting. Check: mcserver status")
    try:
        return [COLOR_RE.sub("", r.cmd(c)).strip() for c in commands]
    finally:
        r.close()


def rcon1(command):
    return rcon(command)[0]


# ----------------------------------------------------------------- server state
def server_pid():
    r = subprocess.run(["pgrep", "-u", USER, "-x", "java"], capture_output=True, text=True)
    pids = r.stdout.split()
    return int(pids[0]) if pids else None


def server_ready():
    try:
        rcon("list")
        return True
    except (UserError, OSError):
        return False


def service_state():
    return subprocess.run(["systemctl", "is-active", SERVICE], capture_output=True, text=True).stdout.strip()


def wait_ready(timeout=300, quiet=False):
    end = time.time() + timeout
    while time.time() < end:
        if server_ready():
            return True
        if service_state() in ("failed", "inactive"):
            break
        time.sleep(2)
        if not quiet:
            print(".", end="", flush=True)
    if not quiet:
        print()
    return False


def start_server(wait=True):
    subprocess.run(["systemctl", "start", SERVICE])
    if wait:
        print("Starting the server (loading the world can take a minute)", end="", flush=True)
        ok = wait_ready()
        print(" ready." if ok else "\nThe server didn't finish starting. Check: mcserver logs")
        return ok
    return True


def stop_server():
    if service_state() == "active" or server_pid():
        print("Stopping the server (saving the world first)...")
        subprocess.run(["systemctl", "stop", SERVICE])


def restart_server():
    stop_server()
    return start_server()


def maybe_restart(flags, what):
    if "--restart" in flags:
        restart_server()
    elif "--no-restart" in flags or not server_pid():
        if server_pid():
            print(f"Run 'mcserver restart' to load {what}.")
    elif ask_yes(f"Restart the server now to load {what}? Players will be disconnected for a minute."):
        restart_server()
    else:
        print(f"OK. Run 'mcserver restart' later to load {what}.")


def players():
    """Returns (online, max, [names]) or None if the server isn't reachable."""
    try:
        out = rcon1("list")
    except UserError:
        return None
    m = re.search(r"There are (\d+) of a max(?: of)? (\d+) players online:?\s*(.*)", out, re.S)
    if not m:
        return None
    names = [n.strip() for n in m.group(3).replace("\n", ",").split(",") if n.strip()]
    return int(m.group(1)), int(m.group(2)), names


# ----------------------------------------------------------------- server jar
def install_server(kind, want, quiet_note=False):
    """Download the server jar (and Java it needs). Leaves the server stopped/started as it was.
    Returns the resolve() result."""
    print(f"Looking up {type_label(kind)} {want}...")
    res = resolve(kind, want)
    if res["note"] and not quiet_note:
        print("Note: " + res["note"])
    java = ensure_java(res["java"])
    ensure_dir(DIR)
    dest = os.path.join(DIR, res["jar"])
    print(f"Downloading {res['build']}...")
    download(res["url"], dest, res["hashes"])
    prev = ENV.get("MC_TYPE")
    if prev and prev != kind:
        # switching server type: remove the old launcher so the wrong jar can't start
        other = "server.jar" if res["jar"] == "fabric-server.jar" else "fabric-server.jar"
        if os.path.exists(os.path.join(DIR, other)):
            os.remove(os.path.join(DIR, other))
        if load_index():
            print(f"Note: plugins/mods installed for {type_label(prev)} don't carry over to {type_label(kind)}.")
            save_index({})
    set_env("MC_TYPE", kind)
    set_env("MC_VERSION", res["version"])
    set_env("MC_BUILD", res["build"])
    set_env("MC_JAVA", java)
    set_env("MC_JAR", res["jar"])
    set_env("MC_JAVA_MAJOR", str(res["java"]))
    set_env("MC_NOTE", res["note"].replace("\n", " "))
    return res


# ----------------------------------------------------------------- Bedrock crossplay
def geyser_paths():
    return [os.path.join(DIR, "plugins", fname) for _, fname in GEYSER_JARS]


def install_geyser():
    """Download/refresh Geyser + Floodgate. Returns True if anything changed."""
    pdir = ensure_dir(os.path.join(DIR, "plugins"))
    changed = False
    for proj, fname in GEYSER_JARS:
        dest = os.path.join(pdir, fname)
        before = file_sha256(dest) if os.path.exists(dest) else None
        print(f"Downloading {proj.capitalize()}...")
        download(GEYSER_DL.format(proj), dest)
        changed |= file_sha256(dest) != before
    return changed


def cmd_bedrock(args):
    want = args[0].lower() if args else ""
    if want not in ("on", "off"):
        print(f"Bedrock crossplay is {'on' if ENV.get('MC_BEDROCK') == '1' else 'off'}.")
        print("Usage: mcserver bedrock on|off")
        return
    if want == "on":
        if ENV.get("MC_TYPE") != "paper":
            raise UserError("Bedrock crossplay (Geyser) needs a Paper server. Re-run mc-setup.sh and pick Paper.")
        install_geyser()
        set_env("MC_BEDROCK", "1")
    else:
        for p in geyser_paths():
            if os.path.exists(p):
                os.remove(p)
        set_env("MC_BEDROCK", "0")
    configure_firewall()
    print(f"Bedrock crossplay turned {want}.")
    maybe_restart(args[1:], "the change")


# ----------------------------------------------------------------- firewall
def ufw(*args, quiet=False):
    r = subprocess.run(["ufw", *args], capture_output=True, text=True)
    if r.returncode != 0 and not quiet:
        print((r.stderr or r.stdout).strip())
    return r.returncode == 0


def ssh_port():
    r = subprocess.run(["sshd", "-T"], capture_output=True, text=True) if shutil.which("sshd") else None
    m = re.search(r"^port (\d+)", r.stdout if r else "", re.M)
    return m.group(1) if m else "22"


def configure_firewall():
    port = ENV.get("MC_PORT", "25565")
    net = ENV.get("MC_NET", "tailscale")
    bedrock = ENV.get("MC_BEDROCK") == "1"
    rules = [(port, "tcp")] + ([(str(BEDROCK_PORT), "udp")] if bedrock else [])
    ufw("default", "deny", "incoming")
    ufw("default", "allow", "outgoing")
    ufw("allow", f"{ssh_port()}/tcp")   # never lock yourself out of SSH
    # clear rules from any previous run so modes don't stack
    for p, proto in ((port, "tcp"), (str(BEDROCK_PORT), "udp")):
        ufw("delete", "allow", f"{p}/{proto}", quiet=True)
        ufw("delete", "allow", "in", "on", "tailscale0", "to", "any", "port", p, "proto", proto, quiet=True)
        for n in PRIVATE_NETS:
            ufw("delete", "allow", "from", n, "to", "any", "port", p, "proto", proto, quiet=True)
    for p, proto in rules:
        if net == "tailscale":
            ufw("allow", "in", "on", "tailscale0", "to", "any", "port", p, "proto", proto)
        elif net == "public":
            ufw("allow", f"{p}/{proto}")
        else:
            for n in PRIVATE_NETS:
                ufw("allow", "from", n, "to", "any", "port", p, "proto", proto)
    return ufw("--force", "enable")


# ----------------------------------------------------------------- players
def split_names(args):
    bedrock = "--bedrock" in args
    names = [a for a in args if not a.startswith("--")]
    return names, bedrock


def check_names(names, bedrock):
    bad = [n for n in names if not (GAMERTAG_RE if bedrock else NAME_RE).match(n)]
    if bad:
        what = "Xbox gamertag" if bedrock else "Minecraft Java username (letters, numbers, _ only; max 16)"
        raise UserError(f"not a valid {what}: {', '.join(bad)}")


def cmd_whitelist(args):
    sub = args[0].lower() if args else "list"
    names, bedrock = split_names(args[1:])
    if sub in ("on", "off"):
        set_props({"white-list": "true" if sub == "on" else "false",
                   "enforce-whitelist": "true" if sub == "on" else "false"})
        if server_pid():
            print(rcon1(f"whitelist {sub}"))
        print("Whitelist is " + ("ON: only players you add can join." if sub == "on"
                                 else "OFF: anyone who can reach the server can join."))
        return
    if sub == "list":
        print(rcon1("whitelist list") if server_pid() else _whitelist_from_file())
        return
    if sub not in ("add", "remove") or not names:
        die("usage: mcserver whitelist add|remove <name>... [--bedrock]   |   mcserver whitelist on|off|list")
    check_names(names, bedrock)
    if bedrock and ENV.get("MC_BEDROCK") != "1":
        raise UserError("Bedrock crossplay is off. Turn it on first: mcserver bedrock on")
    for n in names:
        cmd = f'fwhitelist {sub} "{n}"' if bedrock else f"whitelist {sub} {n}"
        print(rcon1(cmd) or f"{sub}: {n}")
    if bedrock and sub == "add":
        print("Bedrock players show up in-game with a '.' in front of their name.")


def _whitelist_from_file():
    p = os.path.join(DIR, "whitelist.json")
    try:
        with open(p) as f:
            names = [e.get("name", "?") for e in json.load(f)]
    except (OSError, ValueError):
        names = []
    return ("Whitelisted: " + ", ".join(names)) if names else "Nobody is whitelisted yet."


def cmd_op(args, remove=False):
    names, _ = split_names(args)
    if not names:
        die(f"usage: mcserver {'deop' if remove else 'op'} <name>")
    check_names(names, False)
    for n in names:
        print(rcon1(f"{'deop' if remove else 'op'} {n}"))


def cmd_players(_args):
    p = players()
    if p is None:
        die("the server isn't running (or is still starting).")
    online, mx, names = p
    print(f"{online}/{mx} players online" + (": " + ", ".join(names) if names else ""))


# ----------------------------------------------------------------- plugins & mods (Modrinth)
def load_index():
    try:
        with open(INDEX) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_index(idx):
    with open(INDEX, "w") as f:
        json.dump(idx, f, indent=2)
    chown_user(INDEX)


def loaders():
    return ["paper", "spigot", "bukkit", "purpur"] if ENV.get("MC_TYPE") == "paper" else ["fabric"]


def safe_jar_name(name):
    name = re.sub(r"[^A-Za-z0-9._+-]", "_", os.path.basename(name))
    return name if name.lower().endswith(".jar") else name + ".jar"


def parse_modrinth(s):
    """Modrinth link or slug -> slug/id, else None."""
    m = re.match(r"^https?://(?:www\.)?modrinth\.com/(?:plugin|mod|project)/([^/?#]+)", s)
    if m:
        return m.group(1)
    if re.fullmatch(r"[A-Za-z0-9_.-]{2,64}", s) and not s.lower().endswith(".jar"):
        return s
    return None


def modrinth_version(pid, version):
    q = urllib.parse.urlencode({"loaders": json.dumps(loaders()), "game_versions": json.dumps([version])})
    vs = fetch_json(f"{MODRINTH}/project/{pid}/version?{q}")
    releases = [v for v in vs if v.get("version_type") == "release"]
    return (releases or vs or [None])[0]


def modrinth_install(ref, idx, seen, version=None, dep=False):
    version = version or ENV.get("MC_VERSION")
    try:
        proj = fetch_json(f"{MODRINTH}/project/{urllib.parse.quote(ref)}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise UserError(f"'{ref}' isn't a Modrinth project. Paste the link from modrinth.com.")
        raise
    pid, title = proj["id"], proj.get("title", ref)
    if pid in seen:
        return
    seen.add(pid)
    ptype = proj.get("project_type")
    if ptype not in ("mod", "plugin"):
        raise UserError(f"{title} is a {ptype}, not a plugin or mod - only those can be installed here.")
    if proj.get("server_side") == "unsupported":
        print(f"Skipping {title}: it's client-only (each player installs it themselves).")
        return
    ver = modrinth_version(pid, version)
    if not ver:
        kind = "Paper plugin" if ENV.get("MC_TYPE") == "paper" else "Fabric mod"
        raise UserError(f"{title} has no {kind} version for Minecraft {version}.")
    f = next((x for x in ver["files"] if x.get("primary")), ver["files"][0])
    ddir = ensure_dir(addon_dir())
    fname = safe_jar_name(f["filename"])
    old = idx.get(pid, {}).get("file")
    if old and old != fname and os.path.exists(os.path.join(ddir, old)):
        os.remove(os.path.join(ddir, old))
    sha = (f.get("hashes") or {}).get("sha512")
    if idx.get(pid, {}).get("version_id") == ver["id"] and os.path.exists(os.path.join(ddir, fname)):
        print(f"{title} is already up to date ({ver.get('version_number')}).")
    else:
        print(f"{'  + dependency ' if dep else 'Installing '}{title} {ver.get('version_number', '')}")
        download(f["url"], os.path.join(ddir, fname), {"sha512": sha} if sha else None)
    idx[pid] = {"title": title, "slug": proj.get("slug"), "file": fname, "version_id": ver["id"],
                "version": ver.get("version_number"), "source": "modrinth"}
    for d in ver.get("dependencies") or []:
        if d.get("dependency_type") == "required" and d.get("project_id"):
            modrinth_install(d["project_id"], idx, seen, version, dep=True)


def add_file_or_url(target, idx):
    ddir = ensure_dir(addon_dir())
    if os.path.isfile(target):
        if not target.lower().endswith(".jar"):
            raise UserError(f"{target} isn't a .jar file.")
        fname = safe_jar_name(target)
        shutil.copy(target, os.path.join(ddir, fname))
        chown_user(os.path.join(ddir, fname))
    elif re.match(r"^https?://", target):
        fname = safe_jar_name(urllib.parse.urlparse(target).path)
        print(f"Downloading {fname}...")
        download(target, os.path.join(ddir, fname))
    else:
        raise UserError(f"don't know how to install '{target}'. Use a Modrinth link or name, a .jar URL, or a .jar file.")
    idx["file:" + fname] = {"title": fname, "file": fname, "source": "file"}
    print(f"Installed {fname}. (Files and URLs aren't updated automatically.)")


def cmd_add(args):
    targets = [a for a in args if not a.startswith("--")]
    if not targets:
        die("usage: mcserver add <modrinth link or name | .jar URL | .jar file>...")
    addon_dir()   # fails early on Vanilla
    idx, seen, failed = load_index(), set(), []
    for t in targets:
        try:
            slug = None if (os.path.isfile(t) or re.match(r"^https?://(?!(www\.)?modrinth\.com)", t)) else parse_modrinth(t)
            if slug:
                modrinth_install(slug, idx, seen)
            else:
                add_file_or_url(t, idx)
        except (UserError, urllib.error.URLError, OSError, KeyError, ValueError) as e:
            print(f"Couldn't install {t}: {e}")
            failed.append(t)
        finally:
            save_index(idx)
    if len(failed) < len(targets):
        maybe_restart(args, "the new plugins/mods" if ENV.get("MC_TYPE") == "paper" else "the new mods")
    if failed:
        sys.exit(1)


def find_addon(arg, idx):
    a = arg.lower()
    for k, m in idx.items():
        if a in (k.lower(), (m.get("slug") or "").lower(), (m.get("title") or "").lower(), m["file"].lower()):
            return k
    return None


def cmd_remove(args):
    targets = [a for a in args if not a.startswith("--")]
    if not targets:
        die("usage: mcserver remove <name>   (see: mcserver addons)")
    idx, ddir = load_index(), addon_dir()
    for t in targets:
        k = find_addon(t, idx)
        if not k:
            print(f"'{t}' isn't installed. See: mcserver addons")
            continue
        p = os.path.join(ddir, idx[k]["file"])
        if os.path.exists(p):
            os.remove(p)
        print(f"Removed {idx.pop(k)['title']}.")
    save_index(idx)
    maybe_restart(args, "the change")


def cmd_addons(_args=None):
    idx = load_index()
    if not idx:
        print("No plugins or mods installed with 'mcserver add'.")
    for m in sorted(idx.values(), key=lambda m: m["title"].lower()):
        print(f"  {m['title']:<32} {m.get('version') or '':<18} {m.get('slug') or m['file']}")
    if ENV.get("MC_BEDROCK") == "1":
        print("  (plus Geyser + Floodgate for Bedrock crossplay)")


def update_addons(version, idx=None, dry_run=False):
    """Refresh Modrinth addons for a Minecraft version. Returns titles with no compatible version."""
    idx = load_index() if idx is None else idx
    missing = []
    for pid, m in list(idx.items()):
        if m.get("source") != "modrinth":
            continue
        try:
            if dry_run:
                if not modrinth_version(pid, version):
                    missing.append(m["title"])
            else:
                modrinth_install(pid, idx, set(), version)
        except UserError:
            missing.append(m["title"])
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            print(f"Couldn't check {m['title']}: {e}")
    if not dry_run:
        save_index(idx)
    return missing


# ----------------------------------------------------------------- backups
def list_backups():
    if not os.path.isdir(BACKUPS):
        return []
    return sorted((f for f in os.listdir(BACKUPS) if f.endswith(".tar.gz")), reverse=True)


def _backup_filter(ti):
    parts = ti.name.split("/")
    if ".paper-remapped" in parts or "cache" in parts[1:2] or ti.name.endswith(".part"):
        return None
    return ti


def make_backup(tag="manual", quiet=False):
    ensure_dir(BACKUPS)
    os.chmod(BACKUPS, 0o750)
    name = f"backup-{time.strftime('%Y%m%d-%H%M%S')}-{tag}.tar.gz"
    dest, tmp = os.path.join(BACKUPS, name), os.path.join(BACKUPS, name + ".part")
    live = server_ready()
    if live:
        rcon("save-off", "save-all flush")   # pause autosave so files don't change mid-backup
    try:
        if not quiet:
            print(f"Backing up to {dest} ...")
        with tarfile.open(tmp, "w:gz") as t:
            for entry in sorted(os.listdir(DIR)):
                if entry in BACKUP_SKIP or entry.endswith((".jar", ".part")):
                    continue
                t.add(os.path.join(DIR, entry), arcname=entry, filter=_backup_filter)
        os.replace(tmp, dest)
        chown_user(dest)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
        if live:
            try:
                rcon("save-on")
            except UserError:
                pass
    if not quiet:
        print(f"Done: {name} ({human(os.path.getsize(dest))})")
    return dest


def prune_backups(keep):
    autos = [f for f in list_backups() if f.endswith("-auto.tar.gz")]
    for f in autos[keep:]:
        os.remove(os.path.join(BACKUPS, f))


def cmd_backup(args):
    auto = "--auto" in args
    if auto and not os.path.isdir(os.path.join(DIR, level_name())):
        return   # nothing to back up yet
    make_backup("auto" if auto else "manual", quiet=auto)
    if auto:
        prune_backups(int(ENV.get("MC_BACKUP_KEEP") or 7))


def level_name():
    return read_props().get("level-name") or "world"


def cmd_backups(_args=None):
    files = list_backups()
    if not files:
        print("No backups yet. Make one with: mcserver backup")
    for f in files:
        print(f"  {f}  {human(os.path.getsize(os.path.join(BACKUPS, f)))}")
    print(f"\nFolder: {BACKUPS}\nDaily backups (…-auto) keep the newest {ENV.get('MC_BACKUP_KEEP') or 7}; "
          "manual and pre-update backups stay until you delete them.")


def safe_members(t):
    for m in t.getmembers():
        name = m.name
        if name.startswith("/") or ".." in name.split("/") or m.issym() or m.islnk() or m.isdev():
            raise UserError(f"refusing to restore suspicious path in backup: {name}")
        yield m


def cmd_restore(args, from_menu=False):
    files = list_backups()
    if not files:
        die("no backups found.")
    pick = next((a for a in args if not a.startswith("--")), None)
    if from_menu and not pick:
        pick = wt_menu("Restore which backup? The current world is backed up first.",
                       [(f, human(os.path.getsize(os.path.join(BACKUPS, f)))) for f in files])
        if not pick:
            return
    if not pick:
        cmd_backups()
        die("usage: mcserver restore <backup file name>")
    path = pick if os.path.isabs(pick) else os.path.join(BACKUPS, os.path.basename(pick))
    if not os.path.isfile(path):
        die(f"{pick} not found. See: mcserver backups")
    if "--yes" not in args and not ask_yes(f"Replace the current world and settings with {os.path.basename(path)}?\n"
                                           "The server restarts; the current world is backed up first."):
        print("Cancelled.")
        return
    stop_server()
    safety = make_backup("before-restore")
    with tarfile.open(path, "r:gz") as t:
        members = list(safe_members(t))
        tops = {m.name.split("/")[0] for m in members}
        for top in tops:
            p = os.path.join(DIR, top)
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            elif os.path.lexists(p):
                os.remove(p)
        t.extractall(DIR, members=members)
    chown_tree(DIR)
    print(f"Restored {os.path.basename(path)}. (Previous state saved as {os.path.basename(safety)})")
    start_server()


# ----------------------------------------------------------------- update
def cmd_update(args):
    want = None
    if "--version" in args:
        i = args.index("--version")
        want = args[i + 1] if i + 1 < len(args) else die("--version needs a value, e.g. 26.3 or latest")
    kind, cur = ENV.get("MC_TYPE"), ENV.get("MC_VERSION")
    res = resolve(kind, want or cur)
    newv = res["version"]
    if vkey(newv) and vkey(cur) and vkey(newv) < vkey(cur) and "--force" not in args:
        die(f"{newv} is older than your world ({cur}). Downgrading can corrupt the world; "
            "restore a backup made on that version instead.")
    changing = newv != cur
    if changing:
        print(f"This moves the server from Minecraft {cur} to {newv}.")
        print("Worlds can't be moved back to an older version, so a backup is made first.")
        print(f"Everyone will need Minecraft Java {newv} to join.")
        missing = update_addons(newv, dry_run=True)
        if missing:
            print("These plugins/mods have no version for " + newv + " yet and will stay on their old version "
                  "(they may break): " + ", ".join(missing))
        if res["note"]:
            print("Note: " + res["note"])
        if "--yes" not in args and not ask_yes("Continue?"):
            print("Cancelled.")
            return
    elif res["build"] == ENV.get("MC_BUILD"):
        print(f"{res['build']} is already the newest build.")
    java = ensure_java(res["java"])

    # download everything before stopping, so a failed download doesn't cause downtime
    staged = os.path.join(DIR, res["jar"] + ".new")
    new_jar = res["build"] != ENV.get("MC_BUILD") or "--force" in args
    if new_jar:
        print(f"Downloading {res['build']}...")
        download(res["url"], staged, res["hashes"])
    running = bool(server_pid())
    if new_jar or changing:
        if running:
            stop_server()
        make_backup("pre-update")
        if new_jar:
            os.replace(staged, os.path.join(DIR, res["jar"]))
        for k, v in (("MC_VERSION", newv), ("MC_BUILD", res["build"]), ("MC_JAVA", java),
                     ("MC_JAR", res["jar"]), ("MC_JAVA_MAJOR", str(res["java"])),
                     ("MC_NOTE", res["note"].replace("\n", " "))):
            set_env(k, v)
    before = {m["file"] for m in load_index().values()}
    update_addons(newv)
    changed = new_jar or changing or before != {m["file"] for m in load_index().values()}
    if ENV.get("MC_BEDROCK") == "1":
        try:
            changed |= install_geyser()
        except (UserError, urllib.error.URLError, OSError) as e:
            print(f"Warning: couldn't update Geyser/Floodgate ({e}).")
    if new_jar or changing:
        start_server() if running or "--start" in args else print("Update done. Start it with: mcserver start")
    elif changed and running:
        maybe_restart(args, "the updated plugins/mods")
    else:
        print("Everything is up to date.")


# ----------------------------------------------------------------- status / info
def status_text():
    state = service_state()
    pid = server_pid()
    lines = [f"Service       : {state}",
             f"Server        : {'running' if pid else 'NOT running'} - {ENV.get('MC_BUILD', '?')}",
             f"Memory        : {ENV.get('MC_RAM', '?')}"]
    p = players() if pid else None
    if p:
        lines.append(f"Players       : {p[0]}/{p[1]} online" + (" - " + ", ".join(p[2]) if p[2] else ""))
    elif pid:
        lines.append("Players       : (server still starting)")
    props = read_props()
    lines.append(f"Whitelist     : {'on' if props.get('white-list') == 'true' else 'OFF - anyone can join'}")
    if ENV.get("MC_TYPE") != "vanilla":
        lines.append(f"Plugins/mods  : {len(load_index())} installed")
    lines.append(f"Bedrock       : {'on (port %d)' % BEDROCK_PORT if ENV.get('MC_BEDROCK') == '1' else 'off'}")
    b = list_backups()
    lines.append(f"Last backup   : {b[0] if b else 'none yet'}")
    return "\n".join(lines)


def info_text():
    if not os.path.exists(INFO):
        return "No info file yet."
    with open(INFO) as f:
        return f.read()


def cmd_logs(_args):
    if not os.path.exists(LOGFILE):
        print("No log yet - start the server first.")
        return
    os.execvp("tail", ["tail", "-n", "50", "-f", LOGFILE])


def cmd_console(_args):
    if not server_pid():
        die("the server isn't running.")
    print("Attaching to the live server console. Commands don't need a '/'.")
    print("Detach with Ctrl+B then D.  Typing 'stop' restarts the server (use 'mcserver stop' to stop it).")
    time.sleep(2)
    os.execvp("sudo", as_user(["tmux", "attach", "-t", SESSION]))


def cmd_config(_args):
    subprocess.run([os.environ.get("EDITOR", "nano"), PROPS])
    chown_user(PROPS)
    if server_pid() and ask_yes("Restart the server to apply the changes?"):
        restart_server()


def cmd_ram(args):
    if not args:
        print(f"The server uses {ENV.get('MC_RAM')}. Change it with e.g.: mcserver ram 4G")
        return
    val = args[0].upper()
    if not RAM_RE.match(val):
        die("use a size like 3G or 3072M")
    mb = int(val[:-1]) * (1024 if val.endswith("G") else 1)
    total_mb = int(re.search(r"MemTotal:\s+(\d+)", open("/proc/meminfo").read()).group(1)) // 1024
    if mb < 512:
        die("that's too little; Minecraft needs at least 1G.")
    if mb > total_mb - 512 and "--force" not in args:
        die(f"this machine has {total_mb} MB of RAM; leave some for the system (add --force to insist).")
    set_env("MC_RAM", val)
    print(f"Memory set to {val}.")
    maybe_restart(args[1:], "the new memory setting")


# ----------------------------------------------------------------- internal (used by mc-setup.sh)
def cmd_internal_install(args):
    opts = dict(zip(args[::2], args[1::2]))
    install_server(opts.get("--type", "paper"), opts.get("--version", "latest"))
    if ENV.get("MC_BEDROCK") == "1":
        install_geyser()
    else:
        for p in geyser_paths():
            if os.path.exists(p):
                os.remove(p)
    if load_index() and ENV.get("MC_TYPE") != "vanilla":
        missing = update_addons(ENV["MC_VERSION"])
        if missing:
            print("No compatible version for: " + ", ".join(missing))


def cmd_internal_props(args):
    set_props(dict(a.split("=", 1) for a in args if "=" in a))


# ----------------------------------------------------------------- whiptail UI
def wt(args):
    r = subprocess.run(["whiptail", "--title", WT_TITLE] + args, stderr=subprocess.PIPE, text=True)
    return r.returncode == 0, r.stderr.strip()


def wt_size(lines=10):
    cols, rows = shutil.get_terminal_size((80, 24))
    return str(max(10, min(rows - 2, lines + 8))), str(max(40, min(cols - 4, 78)))


def wt_msg(text):
    h, w = wt_size(text.count("\n") + 2)
    wt(["--scrolltext", "--msgbox", text, h, w])


def wt_yesno(text):
    if not sys.stdin.isatty():
        return False
    ok, _ = wt(["--yesno", text, "12", "72"])
    return ok


def wt_input(text, init=""):
    ok, val = wt(["--inputbox", text, "12", "76", init])
    return val if ok else None


def wt_menu(text, items, default=None):
    h, w = wt_size(len(items) + 2)
    list_h = str(max(1, min(len(items), int(h) - 8)))
    args = (["--default-item", default] if default else []) + ["--menu", text, h, w, list_h]
    for tag, desc in items:
        args += [tag, desc[:60]]
    ok, val = wt(args)
    return val if ok else None


def pause():
    input("\nPress Enter to return to the menu...")


def in_terminal(fn, *a):
    subprocess.run(["clear"])
    try:
        fn(*a)
    except UserError as e:
        print(f"Error: {e}")
    except SystemExit:
        pass
    pause()


def cmd_menu(_args=None):
    if not sys.stdin.isatty():
        die("the menu needs an interactive terminal.")
    choice = None
    while True:
        items = [("status", "Server status and players online"),
                 ("allow", "Let a friend join (whitelist)"),
                 ("op", "Make someone an operator (admin)")]
        if ENV.get("MC_BEDROCK") == "1":
            items.append(("allowbedrock", "Let a Bedrock (phone/console) friend join"))
        if ENV.get("MC_TYPE") != "vanilla":
            items += [("add", "Add plugins/mods from Modrinth"),
                      ("addons", "List installed plugins/mods"),
                      ("remove", "Remove a plugin/mod")]
        items += [("backup", "Back up the world now"),
                  ("restore", "Restore a backup"),
                  ("restart", "Restart the server"),
                  ("logs", "Show recent server log"),
                  ("console", "Open the live server console"),
                  ("update", "Update the server"),
                  ("info", "How friends connect"),
                  ("exit", "Exit")]
        try:
            head = status_text()
        except Exception:   # never let a status hiccup close the menu
            head = "Status unavailable."
        choice = wt_menu(head + "\n\nWhat do you want to do?", items, choice)
        if choice in (None, "exit"):
            subprocess.run(["clear"])
            return
        if choice == "status":
            wt_msg(status_text())
        elif choice in ("allow", "allowbedrock"):
            bedrock = choice == "allowbedrock"
            val = wt_input(("Xbox gamertag" if bedrock else "Minecraft username") +
                           " to allow (several: separate with spaces" + (", no spaces inside a name)." if bedrock else ")."))
            if val and val.strip():
                in_terminal(cmd_whitelist, ["add"] + val.split() + (["--bedrock"] if bedrock else []))
        elif choice == "op":
            val = wt_input("Minecraft username to make an operator (can use all commands):")
            if val and val.strip():
                in_terminal(cmd_op, val.split())
        elif choice == "add":
            val = wt_input("Paste Modrinth links or names (e.g. https://modrinth.com/plugin/essentialsx).\n"
                           "Separate several with spaces. A .jar URL or a .jar file path works too.")
            if val and val.strip():
                in_terminal(cmd_add, [os.path.abspath(os.path.expanduser(v)) if os.path.isfile(os.path.expanduser(v))
                                      else v for v in val.split()])
        elif choice == "addons":
            in_terminal(cmd_addons)
        elif choice == "remove":
            idx = load_index()
            if not idx:
                wt_msg("No plugins or mods installed.")
                continue
            key = wt_menu("Remove which one?", [(k, m["title"]) for k, m in idx.items()])
            if key and wt_yesno(f"Remove {idx[key]['title']}?"):
                in_terminal(cmd_remove, [key])
        elif choice == "backup":
            in_terminal(cmd_backup, [])
        elif choice == "restore":
            if list_backups():
                subprocess.run(["clear"])
                try:
                    cmd_restore([], from_menu=True)
                except (UserError, SystemExit) as e:
                    print(e if isinstance(e, UserError) else "")
                pause()
            else:
                wt_msg("No backups yet.")
        elif choice == "restart":
            if wt_yesno("Restart the server? Players will be disconnected for a minute."):
                in_terminal(restart_server)
        elif choice == "logs":
            text = "".join(open(LOGFILE, errors="replace").readlines()[-40:]) if os.path.exists(LOGFILE) else "No log yet."
            wt_msg(text)
        elif choice == "console":
            subprocess.run(["clear"])
            cmd_console([])
        elif choice == "update":
            v = wt_menu("Update to:", [("same", f"Newest build of {ENV.get('MC_VERSION')} (safe)"),
                                        ("latest", "Newest Minecraft version (one-way upgrade)")])
            if v:
                in_terminal(cmd_update, [] if v == "same" else ["--version", "latest"])
        elif choice == "info":
            wt_msg(info_text())


# ----------------------------------------------------------------- main
HELP = """Usage: mcserver <command>

  menu                      Interactive menu (same as running 'mcserver' with no command)
  status                    Is the server running? Who's online?
  start | stop | restart    Control the server
  console                   Live server console (detach: Ctrl+B then D)
  logs                      Follow the server log
  config                    Edit server.properties
  info                      Connection details for friends

  whitelist add <name>...   Let players join     (add --bedrock for Xbox gamertags)
  whitelist remove <name>   Remove a player
  whitelist list | on | off
  op <name> / deop <name>   Give or take operator (admin) powers
  players                   Who's online
  say <message>             Message everyone in game
  cmd <command>             Run any server command, e.g.: mcserver cmd time set day

  add <link|name|url|file>  Install plugins (Paper) or mods (Fabric) from Modrinth,
                            with their dependencies. Options: --restart --no-restart
  addons                    List installed plugins/mods
  remove <name>             Uninstall one

  backup                    Back up the world now (daily backups run automatically)
  backups                   List backups
  restore <file>            Restore a backup (the current world is backed up first)

  update                    Newest build of your Minecraft version, plus plugin/mod updates
  update --version <v>      Move to another Minecraft version (e.g. 26.3 or latest)
  ram [size]                Show or set memory, e.g.: mcserver ram 4G
  bedrock on|off            Let Bedrock (phone/console/Windows) players join (Paper only)
"""


def main():
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable, os.path.abspath(__file__)] + sys.argv[1:])
    # resolve file arguments against the directory the user ran us from, before leaving it
    args = [os.path.abspath(a) if not a.startswith("-") and os.path.isfile(a) else a for a in sys.argv[1:]]
    os.chdir("/tmp")
    if not os.path.exists(ENV_FILE):
        die(f"{ENV_FILE} not found - run mc-setup.sh first.")
    init_paths()
    cmd = args[0] if args else ("menu" if sys.stdin.isatty() else "help")
    rest = args[1:]
    try:
        if cmd == "start":
            start_server("--no-wait" not in rest)
        elif cmd == "stop":
            stop_server()
            print("Server stopped. (It starts again on boot; 'mcserver start' starts it now.)")
        elif cmd == "restart":
            restart_server()
        elif cmd == "status":
            print(status_text())
        elif cmd == "players":
            cmd_players(rest)
        elif cmd in ("whitelist", "wl", "allow"):
            cmd_whitelist(rest if cmd != "allow" else ["add"] + rest)
        elif cmd == "op":
            cmd_op(rest)
        elif cmd == "deop":
            cmd_op(rest, remove=True)
        elif cmd == "say":
            print(rcon1("say " + " ".join(rest)) or "Sent.")
        elif cmd == "cmd":
            if not rest:
                die("usage: mcserver cmd <server command>")
            print(rcon1(" ".join(rest).lstrip("/")) or "(no output)")
        elif cmd in ("add", "addplugin", "addmod"):
            cmd_add(rest)
        elif cmd in ("remove", "rm"):
            cmd_remove(rest)
        elif cmd in ("addons", "plugins", "mods"):
            cmd_addons(rest)
        elif cmd == "backup":
            cmd_backup(rest)
        elif cmd == "backups":
            cmd_backups(rest)
        elif cmd == "restore":
            cmd_restore(rest)
        elif cmd == "update":
            cmd_update(rest)
        elif cmd == "ram":
            cmd_ram(rest)
        elif cmd == "bedrock":
            cmd_bedrock(rest)
        elif cmd == "logs":
            cmd_logs(rest)
        elif cmd == "console":
            cmd_console(rest)
        elif cmd == "config":
            cmd_config(rest)
        elif cmd == "info":
            print(info_text())
        elif cmd == "menu":
            cmd_menu(rest)
        elif cmd == "_install":
            cmd_internal_install(rest)
        elif cmd == "_props":
            cmd_internal_props(rest)
        elif cmd == "_firewall":
            configure_firewall() or die("firewall configuration failed")
        elif cmd == "_wait":
            sys.exit(0 if wait_ready(int(rest[0]) if rest else 120, quiet=True) else 1)
        else:
            print(HELP)
    except UserError as e:
        die(str(e))
    except urllib.error.URLError as e:
        die(f"network problem: {getattr(e, 'reason', e)}. Check the internet connection and try again.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nCancelled.")
        sys.exit(130)
MC_HELPER_EOF
  chmod 755 "$HELPER"
}

: >"$FAIL_FILE"
rm -f "$LOG.players"
install_all | whiptail --title "$TITLE" --gauge "Starting..." 12 78 0

if [[ -s "$FAIL_FILE" ]]; then
  whiptail --title "Setup failed" --scrolltext --msgbox \
"$(cat "$FAIL_FILE")

Last lines of the log ($LOG):
$(tail -n 20 "$LOG")" 24 90
  exit 1
fi

# ---------------------------------------------------------------- Tailscale login
TS_IP=""
if [[ "$NET_MODE" == "tailscale" ]]; then
  if ! tailscale status >/dev/null 2>&1; then
    clear
    echo "=================================================================="
    echo "  Tailscale login"
    echo "  Open the link below in any browser and sign in (free account)."
    echo "  This screen continues automatically once you've signed in."
    echo "=================================================================="
    tailscale up || echo "Tailscale login did not complete. Run 'sudo tailscale up' later."
  fi
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
fi

# ---------------------------------------------------------------- summary
LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
PUB_IP=""
[[ "$NET_MODE" == "public" ]] && PUB_IP=$(curl -s --max-time 5 https://api.ipify.org || true)
MC_VERSION=$(prev MC_VERSION)
MC_BUILD=$(prev MC_BUILD)
MC_NOTE=$(prev MC_NOTE)

case "$NET_MODE" in
  tailscale) ADDR=${TS_IP:-<tailscale-ip>}
             HOWTO="Share this machine with friends:
  Tailscale admin console > Machines > ... next to this server > Share.
  Each friend installs Tailscale, accepts the invite, then connects." ;;
  public)    ADDR=${PUB_IP:-<your-public-ip>}
             HOWTO="On a VPS this works right away.
At home: forward TCP $GAME_PORT$( ((BEDROCK)) && echo " and UDP $BEDROCK_PORT") on your router to $LAN_IP.
(If your ISP uses CGNAT, port forwarding won't work - re-run and pick Tailscale.)" ;;
  lan)       ADDR=$LAN_IP
             HOWTO="Only devices on the same network can join." ;;
esac

cat >"$INFO_FILE" <<EOF
Minecraft server - set up $(date)
Server      : $MC_BUILD
Name        : $MOTD
Game mode   : $GAMEMODE / $DIFFICULTY, up to $MAX_PLAYERS players
Memory      : $MC_RAM
Whitelist   : $WHITELIST
Network     : $NET_MODE

JAVA players (need Minecraft Java $MC_VERSION):
  Multiplayer > Add Server > Server Address:  $ADDR
EOF
if ((BEDROCK)); then
  cat >>"$INFO_FILE" <<EOF

BEDROCK players (phone/console/Windows, latest Bedrock version):
  Play > Servers > Add Server > Address: $ADDR   Port: $BEDROCK_PORT
  Whitelist them by Xbox gamertag:  mcserver whitelist add <gamertag> --bedrock
EOF
fi
cat >>"$INFO_FILE" <<EOF

$HOWTO

Manage the server - just type:  mcserver
  (menu: whitelist friends, plugins/mods, backups, restart, logs, update...)
Or directly:
  mcserver whitelist add <name>   mcserver op <name>   mcserver add <modrinth link>
  mcserver status | restart | console | logs | backup | update | help
World backups run daily at 05:00 (server time) into $SRV_HOME/backups
Files: $INSTALL_DIR
Setup log: $LOG
EOF
[[ -n "$MC_NOTE" ]] && printf '\nNote: %s\n' "$MC_NOTE" >>"$INFO_FILE"
if [[ -s "$LOG.players" ]]; then
  printf '\nSome players could not be added (%s).\nTry again with: mcserver whitelist add <name>\n' \
    "$(paste -sd, "$LOG.players")" >>"$INFO_FILE"
fi
if [[ -s "$LOG.warnings" ]]; then
  printf '\nNote: apt reported problems with other software sources on this machine\n(not needed for Minecraft). Details: %s\n' "$LOG.warnings" >>"$INFO_FILE"
fi
chown "$SRV_USER:$SRV_USER" "$INFO_FILE"; chmod 600 "$INFO_FILE"

rows=$(tput lines 2>/dev/null || echo 24); cols=$(tput cols 2>/dev/null || echo 80)
(( rows > 34 )) && rows=34; (( cols > 86 )) && cols=86
whiptail --title "Your server is running!" --scrolltext --msgbox "$(cat "$INFO_FILE")" $((rows-2)) $((cols-2))
clear
cat "$INFO_FILE"
echo
echo "(This info is saved - view it anytime with:  mcserver info)"
