# Minecraft Server

A private Minecraft Java Edition server for our group, set up with one script. The script installs Java and the server, keeps it running in the background, backs up the world every day, locks down the firewall, and gives you an `mcserver` command for everything afterward, including whitelisting friends and installing plugins or mods straight from Modrinth.

## Requirements

- **Ubuntu 22.04 or 24.04** (or an Ubuntu-based distro like Mint), on a 64-bit Intel/AMD **or ARM** machine. ARM works fine for Minecraft, so Oracle Cloud's free ARM servers are a good option.
- **At least 2 GB of RAM** (4 GB or more is comfortable) **and 5 GB of free disk space.** Worlds and backups grow over time.
- **A user account with sudo access.**

This works on a spare PC at home or on a cloud server (VPS). For players in the Philippines, a VPS in Singapore gives the best ping.

## Quick start

Copy `mc-setup.sh` to the machine and run:

```
sudo bash mc-setup.sh
```

The script asks a few questions, then shows a progress bar while it installs. The first start generates the world, which takes a few minutes. When it finishes, a summary screen shows how friends connect. You can see it again anytime with `mcserver info`.

### The setup questions

| Question | What to pick |
|---|---|
| EULA | You must accept Mojang's [EULA](https://aka.ms/MinecraftEULA) to run a server. |
| Server software | **Paper** (recommended): same gameplay, runs faster, supports plugins. **Vanilla**: Mojang's official server. **Fabric**: supports mods. |
| Minecraft version | `latest`, or a specific version like `26.3`. Everyone who joins needs the same version. |
| Server name | Anything. It shows in the multiplayer server list. |
| Game mode | Survival, Creative, Adventure, or Hardcore. |
| Difficulty | Peaceful through Hard. |
| Max players | How many can be online at once. |
| World seed | Optional. Leave blank for a random world. |
| Memory | How much RAM the server gets. 2–3 GB for a few friends, 4–6 GB for more players or mods. |
| Whitelist | Recommended. Only players you add can join. |
| Your username | Your Minecraft Java username. You're whitelisted and made an operator (admin). |
| Friends | Optional. Their Minecraft Java usernames. You can add more later. |
| Bedrock players | Paper only. Lets friends on phones, tablets, consoles and Windows Bedrock join too. See [Bedrock crossplay](#bedrock-crossplay). |
| Network | How friends reach the server. See below. |

The right Java version is installed automatically for the Minecraft version you pick (Java 25 for Minecraft 26.x, Java 21 for 1.20.5–1.21.x).

### Choosing a network mode

**Tailscale (recommended).** Friends connect through Tailscale, a free app that creates a private link between their device and the server. Nothing is exposed to the internet, and it works even if your ISP uses CGNAT, which is common in the Philippines. Near the end of setup you'll get a login link to open in your browser.

**Public.** The game port is open to the internet. This works immediately on a VPS. At home, you also need to forward **TCP port 25565** (and **UDP 19132** for Bedrock players) on your router to the server, and that won't work if your ISP uses CGNAT. Keep the whitelist on: bots scan the internet for open Minecraft servers.

**Local network only.** Only devices on the same home network can join.

You can switch modes later by running the setup script again.

**Behind CGNAT but don't want friends to install Tailscale?** A tunnel service like [playit.gg](https://playit.gg) gives the server a public address without port forwarding. Pick **Local network only** in setup, then install the playit agent on the server following their Linux guide and point a Minecraft Java tunnel at `127.0.0.1:25565`.

## Managing the server

Type `mcserver` on its own to open a menu with everything below. You can also run commands directly:

| Command | What it does |
|---|---|
| `mcserver` or `mcserver menu` | Interactive menu |
| `mcserver status` | Whether the server is running, who's online, last backup |
| `mcserver start` / `stop` / `restart` | Controls the server. Stopping saves the world first. |
| `mcserver console` | Opens the live server console. Detach with **Ctrl+B** then **D**. Typing `stop` there restarts the server; use `mcserver stop` to actually stop it. |
| `mcserver logs` | Follows the server log. Press **Ctrl+C** to exit. |
| `mcserver config` | Edits `server.properties`, then offers to restart. |
| `mcserver info` | Shows connection details for friends. |
| `mcserver help` | Lists all commands. |

The server starts automatically when the machine boots and restarts itself if it crashes.

### Players

| Command | What it does |
|---|---|
| `mcserver whitelist add <name>...` | Let players join. Add `--bedrock` for Xbox gamertags. |
| `mcserver whitelist remove <name>` | Remove a player |
| `mcserver whitelist list` / `on` / `off` | Show the list, or turn the whitelist on or off |
| `mcserver op <name>` / `deop <name>` | Give or take operator (admin) powers |
| `mcserver players` | Who's online |
| `mcserver say <message>` | Message everyone in the game |
| `mcserver cmd <command>` | Run any server command, e.g. `mcserver cmd time set day` |

### Plugins and mods

Paper servers use **plugins**; Fabric servers use **mods**. Vanilla can't load either. Install them from [Modrinth](https://modrinth.com) by link or name. The server picks the newest version that matches your Minecraft version and installs anything it depends on:

```
mcserver add https://modrinth.com/plugin/essentialsx
mcserver add lithium fabric-api
```

A `.jar` download link or a `.jar` file already on the server works too. Then restart when asked.

| Command | What it does |
|---|---|
| `mcserver add <link or name>` | Installs a plugin or mod, plus its required dependencies |
| `mcserver addons` | Lists installed plugins/mods |
| `mcserver remove <name>` | Uninstalls one |

`mcserver update` also updates plugins and mods installed from Modrinth. Client-side mods (minimaps, shaders) are skipped, since each player installs those in their own game. For Fabric, anyone joining usually needs the same mods installed; mods marked as server-only (like Lithium) are the exception.

## Backups

The world is backed up every day at 05:00 (server time) to `/home/minecraft/backups`. The newest 7 daily backups are kept. Backups are also made automatically before every update and restore, and when you re-run setup.

| Command | What it does |
|---|---|
| `mcserver backup` | Back up now (works while people are playing) |
| `mcserver backups` | List backups |
| `mcserver restore <file>` | Restore one. The current world is backed up first, and the server restarts. |

Manual and pre-update backups are kept until you delete them. To keep more daily backups, change `MC_BACKUP_KEEP` in `/etc/mcserver.env`.

Backups stay on the same machine, so copy one somewhere else now and then, for example with `scp`.

## Updating

```
mcserver update
```

This installs the newest build of your current Minecraft version (Paper releases fixes often) and updates plugins and mods. The server goes down for a minute only if something changed.

To move to a newer Minecraft version:

```
mcserver update --version latest
mcserver update --version 26.3
```

This is one-way: a world opened in a newer version can't go back. The script backs up first, warns about plugins or mods that don't support the new version yet, installs a newer Java if needed, and asks before continuing. Everyone then needs the new version to join.

New Minecraft versions come out before Paper and Fabric support them. With `latest`, the script picks the newest version your server software supports properly and tells you if that's not the newest Minecraft.

## Bedrock crossplay

On Paper, the server can also accept players from Minecraft Bedrock Edition (phones, tablets, Xbox, PlayStation, Switch, Windows Bedrock). It uses [Geyser](https://geysermc.org) and Floodgate, free plugins that translate between the two editions, so Bedrock friends don't need a Java account.

Turn it on during setup, or later with `mcserver bedrock on`. Whitelist Bedrock friends by Xbox gamertag:

```
mcserver whitelist add CoolGamer123 --bedrock
```

They show up in-game with a `.` in front of their name. A few Java-only features look or behave slightly differently for them.

Consoles can't run Tailscale, so in Tailscale mode only phones, tablets and PCs can join as Bedrock players. Console friends need Public mode (or a tunnel like playit.gg with a UDP tunnel for port 19132). Consoles also only show a few featured servers by default; phone apps like BedrockTogether are the common workaround.

## How friends join

Send each friend:

1. **The Tailscale invite.** In the [Tailscale admin console](https://login.tailscale.com/admin/machines), click the **…** menu next to the server, choose **Share**, and send them the link. Each friend uses their own free Tailscale account and only gets access to the game server.
2. **The server address,** from `mcserver info`.
3. **The Minecraft version**, also in `mcserver info`, if they're not on the newest.

And make sure they're on the whitelist: `mcserver whitelist add TheirName`.

In short, friends install Tailscale, accept the invite, open Minecraft Java, and go to **Multiplayer → Add Server** and enter the address (like `100.x.x.x`). No port needed. Bedrock players go to **Play → Servers → Add Server** and use the same address with port `19132`.

**If you're the host**, you need Tailscale on your gaming PC too, signed in with the same account as the server. The exception is if you're playing on the server machine itself, in which case you can use `localhost`.

**To let devices on your home network join without Tailscale**, run:

```
sudo ufw allow from 192.168.0.0/16 to any port 25565 proto tcp
```

## Troubleshooting

**Setup failed.** The error screen shows the last lines of the log. The full log is at `/var/log/mc-setup.log`. It's safe to fix the problem and run the script again.

**"The repository ... does not have a Release file."** This means an unrelated software source on your system is broken. The script continues past this, but it's worth cleaning up. For example, to remove the old Ookla Speedtest source:

```
sudo rm $(grep -rl "ookla" /etc/apt/sources.list.d/)
sudo apt-get update
```

**"Paper has no builds for Minecraft ..."** Paper and Fabric take a while to support new Minecraft releases. Use `latest` (which picks what's supported), an older version, or Vanilla.

**Friends can't connect.** Check that the server is running with `mcserver status`, and that they're whitelisted. In Tailscale mode, make sure the friend's Tailscale app is on and your server appears in their list of machines. In public mode at home, check your port forward and whether your ISP uses CGNAT. The easy way to check for CGNAT is to compare the WAN IP in your router with the IP shown on whatismyip.com. If they differ, switch to Tailscale.

**"Outdated client" or "Outdated server".** The friend's game version doesn't match the server's. Java players pick the version in the launcher: **Installations → New installation → Version**.

**"You are not whitelisted on this server."** Run `mcserver whitelist add TheirName`. For Bedrock friends, add `--bedrock` and use their Xbox gamertag.

**The server won't start.** Check `mcserver logs` or the log file at `/home/minecraft/server/logs/latest.log`, and `journalctl -u mcserver`. An `UnsupportedClassVersionError` means the Java version is wrong; re-run `mc-setup.sh` to fix it.

**The server lags.** Give it more memory with `mcserver ram 4G` (leave about 1 GB for the system), or lower `view-distance` and `simulation-distance` with `mcserver config`. Paper is much faster than Vanilla if you're not using it already.

**A plugin or mod broke after an update.** Remove it with `mcserver remove <name>`, or restore the backup made before the update: find it with `mcserver backups`, then run `mcserver restore <file>`.

## Security

The script sets things up to be reasonably safe by default:

- The server runs as its own `minecraft` user with no admin rights, so a problem in the game server or a plugin can't reach the rest of the system.
- The firewall blocks all incoming traffic except SSH and the game port. In Tailscale mode, the game port only accepts connections through Tailscale.
- Online mode is on, so players are checked against their Mojang/Microsoft accounts. The whitelist is on unless you turned it off.
- The remote console (RCON), which the `mcserver` command uses, has a random password and is never opened in the firewall.

To keep it that way:

- Keep Ubuntu updated with `sudo apt update && sudo apt upgrade`, or turn on automatic security updates.
- Keep the whitelist on, and only make people you trust operators.
- Only install plugins and mods from sources you trust. They run with full access to the server's files.
- On a VPS, log in with SSH keys and turn off password login.

## Where things live

| Path | What it is |
|---|---|
| `/home/minecraft/server/` | Server files |
| `/home/minecraft/server/world/` | The world (Paper also uses `world_nether/` and `world_the_end/`) |
| `/home/minecraft/server/server.properties` | Server settings |
| `/home/minecraft/server/plugins/` or `mods/` | Installed plugins (Paper) or mods (Fabric) |
| `/home/minecraft/server/logs/latest.log` | Server log |
| `/home/minecraft/backups/` | World backups |
| `/home/minecraft/addons.json` | Plugins/mods installed with `mcserver add` |
| `/home/minecraft/SERVER-INFO.txt` | Connection details, shown by `mcserver info` |
| `/etc/mcserver.env` | Server type, version, memory, Java and network settings |
| `/etc/systemd/system/mcserver.service` | Background service definition |
| `/etc/systemd/system/mcserver-backup.timer` | Daily backup schedule |
| `/usr/local/bin/mcserver` | The `mcserver` management command |
| `/usr/local/lib/mcserver/stop.sh` | Saves the world and stops the server cleanly |
| `/var/log/mc-setup.log` | Setup log |

## Tests

The `mcserver` command has a test suite that needs no game server and no network:

```
python3 -m unittest discover -s tests -t .
```

## Uninstalling

```
sudo bash mc-setup.sh --uninstall
```

This removes the service, the `mcserver` command and the firewall rules. It then asks whether to delete the world and backups too; say no to keep them in `/home/minecraft`. Java and Tailscale stay installed. To remove them as well, run `sudo apt remove 'openjdk-*-jre-headless' 'temurin-*' tailscale`.
