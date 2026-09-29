"""Tests for the 'mcserver' helper embedded in mc-setup.sh.

Needs no Minecraft server, network or root:
    python3 -m unittest discover -s tests -t .
"""
import importlib.util
import os
import pathlib
import pwd
import re
import socket
import struct
import tarfile
import tempfile
import threading
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load_helper():
    """Extract the Python helper from the heredoc in mc-setup.sh and import it."""
    text = (ROOT / "mc-setup.sh").read_text()
    m = re.search(r"<<'MC_HELPER_EOF'\n(.*?)\nMC_HELPER_EOF\n", text, re.S)
    assert m, "helper heredoc not found in mc-setup.sh"
    path = pathlib.Path(tempfile.mkdtemp()) / "mcserver_helper.py"
    path.write_text(m.group(1))
    spec = importlib.util.spec_from_file_location("mcserver_helper", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mc = load_helper()
ME = pwd.getpwuid(os.getuid()).pw_name


class Base(unittest.TestCase):
    """Points the helper at a throwaway install directory owned by the current user."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = pathlib.Path(self.tmp.name)
        self.home = t / "home"
        self.dir = self.home / "server"
        self.dir.mkdir(parents=True)
        env = t / "mcserver.env"
        env.write_text(f"MC_USER={ME}\nMC_HOME={self.home}\nMC_DIR={self.dir}\nMC_TYPE=paper\n"
                       "MC_VERSION=26.2\nMC_RAM=2G\nMC_JVM_FLAGS=-XX:+UseG1GC -XX:MaxGCPauseMillis=200\n")
        p = mock.patch.object(mc, "ENV_FILE", str(env))
        p.start()
        self.addCleanup(p.stop)
        mc.init_paths()
        mc._manifest = None

    def tearDown(self):
        self.tmp.cleanup()


class TestEnvAndProps(Base):
    def test_env_values_with_spaces(self):
        self.assertEqual(mc.ENV["MC_JVM_FLAGS"], "-XX:+UseG1GC -XX:MaxGCPauseMillis=200")
        mc.set_env("MC_RAM", "4G")
        mc.set_env("MC_NEW", "x y")
        env = mc.load_env(mc.ENV_FILE)
        self.assertEqual((env["MC_RAM"], env["MC_NEW"]), ("4G", "x y"))

    def test_props_keep_comments_and_order(self):
        pathlib.Path(mc.PROPS).write_text("#Minecraft server properties\nmotd=Old\nview-distance=10\n")
        mc.set_props({"motd": "New = name", "enable-rcon": "true"})
        text = pathlib.Path(mc.PROPS).read_text()
        self.assertEqual(text, "#Minecraft server properties\nmotd=New = name\nview-distance=10\nenable-rcon=true\n")
        self.assertEqual(mc.read_props()["motd"], "New = name")
        self.assertEqual(oct(os.stat(mc.PROPS).st_mode & 0o777), "0o640")

    def test_vkey(self):
        self.assertLess(mc.vkey("1.21.11"), mc.vkey("26.1"))
        self.assertLess(mc.vkey("26.1"), mc.vkey("26.1.2"))
        self.assertIsNone(mc.vkey("26.4-snapshot-1"))
        self.assertIsNone(mc.vkey("26.3-rc1"))


MANIFEST = {"latest": {"release": "26.3"},
            "versions": [{"id": "26.3", "url": "https://m/26.3.json"},
                         {"id": "26.2", "url": "https://m/26.2.json"},
                         {"id": "1.21.11", "url": "https://m/1.21.11.json"}]}
META = {"https://m/26.3.json": {"javaVersion": {"majorVersion": 25},
                                "downloads": {"server": {"url": "https://srv/26.3.jar", "sha1": "abc"}}},
        "https://m/26.2.json": {"javaVersion": {"majorVersion": 25},
                                "downloads": {"server": {"url": "https://srv/26.2.jar", "sha1": "def"}}},
        "https://m/1.21.11.json": {"javaVersion": {"majorVersion": 21},
                                   "downloads": {"server": {"url": "https://srv/1.21.11.jar", "sha1": "ghi"}}}}


def paper_build(i, channel):
    return {"id": i, "channel": channel, "downloads": {"server:default": {
        "url": f"https://paper/{i}.jar", "checksums": {"sha256": f"sha{i}"}}}}


class TestResolve(Base):
    def fake_api(self, paper_builds):
        def fetch_json(url):
            if url == mc.MOJANG_MANIFEST:
                return MANIFEST
            if url in META:
                return META[url]
            if url == mc.PAPER_API:
                return {"versions": {"26": ["26.3", "26.2", "26.4-pre1"], "1.21": ["1.21.11"]}}
            m = re.match(re.escape(mc.PAPER_API) + r"/versions/([^/]+)/builds$", url)
            if m:
                return paper_builds.get(m.group(1), {"ok": False, "message": "not found"})
            if url.endswith("/game"):
                return [{"version": "26.4-snapshot-1", "stable": False}, {"version": "26.3", "stable": True}]
            if url.endswith("/loader"):
                return [{"version": "0.20.0", "stable": False}, {"version": "0.19.2", "stable": True}]
            if url.endswith("/installer"):
                return [{"version": "1.2.0", "stable": True}]
            raise AssertionError(url)
        return mock.patch.object(mc, "fetch_json", side_effect=fetch_json)

    def test_vanilla_latest(self):
        with self.fake_api({}):
            r = mc.resolve("vanilla", "latest")
        self.assertEqual((r["version"], r["url"], r["hashes"], r["java"]), ("26.3", "https://srv/26.3.jar", {"sha1": "abc"}, 25))

    def test_vanilla_old_version_needs_old_java(self):
        with self.fake_api({}):
            self.assertEqual(mc.resolve("vanilla", "1.21.11")["java"], 21)

    def test_unknown_version(self):
        with self.fake_api({}), self.assertRaises(mc.UserError):
            mc.resolve("vanilla", "9.9")

    def test_paper_prefers_newest_stable(self):
        builds = {"26.3": [paper_build(5, "BETA"), paper_build(6, "BETA")],
                  "26.2": [paper_build(40, "STABLE"), paper_build(41, "STABLE"), paper_build(42, "ALPHA")]}
        with self.fake_api(builds):
            r = mc.resolve("paper", "latest")
        self.assertEqual(r["version"], "26.2")
        self.assertEqual(r["url"], "https://paper/41.jar")
        self.assertEqual(r["hashes"], {"sha256": "sha41"})
        self.assertIn("26.3", r["note"])    # explains why it isn't the newest Minecraft

    def test_paper_specific_version_beta_only(self):
        with self.fake_api({"26.3": [paper_build(5, "BETA"), paper_build(6, "BETA")]}):
            r = mc.resolve("paper", "26.3")
        self.assertEqual(r["url"], "https://paper/6.jar")
        self.assertIn("experimental", r["note"])
        self.assertIn("beta", r["build"])

    def test_paper_missing_version(self):
        with self.fake_api({}), self.assertRaises(mc.UserError):
            mc.resolve("paper", "1.21.11")

    def test_fabric(self):
        with self.fake_api({}):
            r = mc.resolve("fabric", "latest")
        self.assertEqual(r["url"], f"{mc.FABRIC_API}/loader/26.3/0.19.2/1.2.0/server/jar")
        self.assertEqual(r["jar"], "fabric-server.jar")


class FakeRconServer(threading.Thread):
    """Speaks just enough of Minecraft's RCON to test the client."""

    def __init__(self, password, replies):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.password, self.replies, self.received = password, replies, []

    def packet(self, rid, typ, body):
        data = struct.pack("<ii", rid, typ) + body.encode() + b"\x00\x00"
        return struct.pack("<i", len(data)) + data

    def run(self):
        conn, _ = self.sock.accept()
        self.sock.close()
        with conn:
            while True:
                try:
                    head = conn.recv(4)
                except OSError:
                    return
                if not head:
                    return
                n = struct.unpack("<i", head)[0]
                data = b""
                while len(data) < n:
                    data += conn.recv(n - len(data))
                rid, typ = struct.unpack("<ii", data[:8])
                body = data[8:-2].decode()
                if typ == 3:
                    conn.sendall(self.packet(rid if body == self.password else -1, 2, ""))
                else:
                    self.received.append(body)
                    conn.sendall(self.packet(rid, 0, self.replies.get(body, "")))


class TestRcon(Base):
    def start(self, password="pw", replies=None):
        srv = FakeRconServer("pw", replies or {})
        srv.start()
        pathlib.Path(mc.PROPS).write_text(f"enable-rcon=true\nrcon.port={srv.port}\nrcon.password={password}\n")
        return srv

    def test_command_and_color_codes(self):
        srv = self.start(replies={"list": "There are 2 of a max of 10 players online: §aAlex, Steve"})
        self.assertEqual(mc.players(), (2, 10, ["Alex", "Steve"]))
        self.assertEqual(srv.received, ["list"])

    def test_empty_server(self):
        self.start(replies={"list": "There are 0 of a max of 10 players online: "})
        self.assertEqual(mc.players(), (0, 10, []))

    def test_wrong_password(self):
        srv = self.start(password="nope")
        self.addCleanup(srv.sock.close)
        with self.assertRaises(mc.UserError):
            mc.rcon("list")

    def test_not_running(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        pathlib.Path(mc.PROPS).write_text(f"enable-rcon=true\nrcon.port={port}\nrcon.password=x\n")
        with self.assertRaises(mc.UserError):
            mc.rcon("list")
        self.assertIsNone(mc.players())


class TestBackups(Base):
    def make_world(self):
        (self.dir / "world" / "region").mkdir(parents=True)
        (self.dir / "world" / "level.dat").write_text("original")
        (self.dir / "plugins" / "Geyser").mkdir(parents=True)
        (self.dir / "plugins" / "Geyser" / "config.yml").write_text("x")
        (self.dir / "plugins" / ".paper-remapped").mkdir()
        (self.dir / "plugins" / ".paper-remapped" / "big.jar").write_text("x")
        (self.dir / "libraries").mkdir()
        (self.dir / "server.jar").write_text("jar")
        (self.dir / "server.properties").write_text("motd=x\n")

    def test_backup_contents(self):
        self.make_world()
        with mock.patch.object(mc, "server_ready", return_value=False):
            path = mc.make_backup("manual", quiet=True)
        names = tarfile.open(path).getnames()
        self.assertIn("world/level.dat", names)
        self.assertIn("server.properties", names)
        self.assertIn("plugins/Geyser/config.yml", names)
        for skipped in ("server.jar", "libraries", "plugins/.paper-remapped/big.jar"):
            self.assertNotIn(skipped, names)

    def test_live_backup_pauses_autosave(self):
        self.make_world()
        calls = []
        with mock.patch.object(mc, "server_ready", return_value=True), \
             mock.patch.object(mc, "rcon", side_effect=lambda *c: calls.append(c) or [""] * len(c)):
            mc.make_backup("manual", quiet=True)
        self.assertEqual(calls, [("save-off", "save-all flush"), ("save-on",)])

    def test_prune_only_auto(self):
        os.makedirs(mc.BACKUPS)
        names = [f"backup-2026090{d}-050000-auto.tar.gz" for d in range(1, 10)] + ["backup-20260901-120000-manual.tar.gz"]
        for n in names:
            pathlib.Path(mc.BACKUPS, n).write_text("x")
        mc.prune_backups(3)
        left = sorted(os.listdir(mc.BACKUPS))
        self.assertEqual(len(left), 4)
        self.assertIn("backup-20260901-120000-manual.tar.gz", left)
        self.assertIn("backup-20260909-050000-auto.tar.gz", left)

    def test_restore_replaces_world_and_keeps_safety_copy(self):
        self.make_world()
        with mock.patch.object(mc, "server_ready", return_value=False):
            good = mc.make_backup("manual", quiet=True)
        (self.dir / "world" / "level.dat").write_text("griefed")
        (self.dir / "world" / "junk").write_text("new file")
        with mock.patch.object(mc, "server_ready", return_value=False), \
             mock.patch.object(mc, "stop_server"), mock.patch.object(mc, "start_server"), \
             mock.patch.object(mc, "make_backup", wraps=mc.make_backup) as mb:
            mc.cmd_restore([os.path.basename(good), "--yes"])
        self.assertEqual((self.dir / "world" / "level.dat").read_text(), "original")
        self.assertFalse((self.dir / "world" / "junk").exists())
        self.assertTrue((self.dir / "server.jar").exists())   # jars aren't in backups, so they're kept
        mb.assert_called_once_with("before-restore")

    def test_restore_rejects_path_traversal(self):
        os.makedirs(mc.BACKUPS)
        evil = pathlib.Path(mc.BACKUPS, "evil.tar.gz")
        with tarfile.open(evil, "w:gz") as t:
            info = tarfile.TarInfo("../escape.txt")
            info.size = 0
            t.addfile(info)
        with mock.patch.object(mc, "server_ready", return_value=False), \
             mock.patch.object(mc, "stop_server"), mock.patch.object(mc, "start_server"):
            with self.assertRaises(mc.UserError):
                mc.cmd_restore(["evil.tar.gz", "--yes"])
        self.assertFalse(pathlib.Path(self.home, "escape.txt").exists())


class TestModrinth(Base):
    PROJECTS = {
        "essentialsx": {"id": "P1", "slug": "essentialsx", "title": "EssentialsX", "project_type": "plugin",
                        "server_side": "required"},
        "P1": None, "DEP": {"id": "DEP", "slug": "dep", "title": "Needed Library", "project_type": "plugin",
                            "server_side": "required"},
        "shader": {"id": "S", "slug": "shader", "title": "Pretty", "project_type": "shader"},
        "minimap": {"id": "C", "slug": "minimap", "title": "Minimap", "project_type": "mod", "server_side": "unsupported"},
    }

    def fake(self, versions):
        projects = dict(self.PROJECTS)
        projects["P1"] = projects["essentialsx"]

        def fetch_json(url):
            m = re.match(re.escape(mc.MODRINTH) + r"/project/([^/?]+)(/version\?(.*))?$", url)
            ref = m.group(1)
            if m.group(2):
                self.queries.append(m.group(3))
                return versions.get(ref, [])
            if projects.get(ref) is None:
                import urllib.error
                raise urllib.error.HTTPError(url, 404, "nf", {}, None)
            return projects[ref]

        def download(url, dest, hashes=None, quiet=False):
            self.downloads.append((url, os.path.basename(dest), hashes))
            pathlib.Path(dest).write_text("jar")
            return dest
        self.queries, self.downloads = [], []
        return mock.patch.multiple(mc, fetch_json=mock.DEFAULT, download=mock.DEFAULT), fetch_json, download

    def run_add(self, versions, args):
        p, fj, dl = self.fake(versions)
        with p as m:
            m["fetch_json"].side_effect = fj
            m["download"].side_effect = dl
            try:
                mc.cmd_add(args + ["--no-restart"])
            except SystemExit as e:
                return e.code
        return 0

    def ver(self, vid, fname, deps=(), vtype="release"):
        return {"id": vid, "version_number": vid, "version_type": vtype,
                "files": [{"url": f"https://cdn/{fname}", "filename": fname, "primary": True,
                           "hashes": {"sha512": "h" + vid}}],
                "dependencies": [{"project_id": d, "dependency_type": "required"} for d in deps]}

    def test_install_with_dependency(self):
        versions = {"P1": [self.ver("b1", "Ess-beta.jar", vtype="beta"), self.ver("r1", "Ess.jar", deps=["DEP"])],
                    "DEP": [self.ver("d1", "Lib.jar")]}
        rc = self.run_add(versions, ["https://modrinth.com/plugin/essentialsx"])
        self.assertEqual(rc, 0)
        self.assertEqual([d[1] for d in self.downloads], ["Ess.jar", "Lib.jar"])   # release preferred over beta
        self.assertEqual(self.downloads[0][2], {"sha512": "hr1"})
        self.assertTrue((self.dir / "plugins" / "Ess.jar").exists())
        self.assertIn("paper", self.queries[0])
        self.assertIn("26.2", self.queries[0])
        idx = mc.load_index()
        self.assertEqual({m["title"] for m in idx.values()}, {"EssentialsX", "Needed Library"})

    def test_update_replaces_old_file(self):
        self.run_add({"P1": [self.ver("r1", "Ess-1.jar")]}, ["essentialsx"])
        self.run_add({"P1": [self.ver("r2", "Ess-2.jar")]}, ["essentialsx"])
        files = sorted(os.listdir(self.dir / "plugins"))
        self.assertEqual(files, ["Ess-2.jar"])

    def test_no_compatible_version(self):
        rc = self.run_add({}, ["essentialsx"])
        self.assertEqual(rc, 1)
        self.assertEqual(mc.load_index(), {})

    def test_rejects_non_plugins_and_skips_client_mods(self):
        self.assertEqual(self.run_add({}, ["shader"]), 1)
        self.run_add({}, ["minimap"])
        self.assertEqual(self.downloads, [])

    def test_remove(self):
        self.run_add({"P1": [self.ver("r1", "Ess.jar")]}, ["essentialsx"])
        mc.cmd_remove(["EssentialsX", "--no-restart"])
        self.assertEqual(os.listdir(self.dir / "plugins"), [])
        self.assertEqual(mc.load_index(), {})

    def test_vanilla_refuses(self):
        mc.ENV["MC_TYPE"] = "vanilla"
        with self.assertRaises(mc.UserError):
            mc.cmd_add(["essentialsx"])

    def test_fabric_uses_mods_folder(self):
        mc.ENV["MC_TYPE"] = "fabric"
        self.run_add({"P1": [self.ver("r1", "Ess.jar")]}, ["essentialsx"])
        self.assertTrue((self.dir / "mods" / "Ess.jar").exists())
        self.assertIn("fabric", self.queries[0])
        self.assertNotIn("paper", self.queries[0])


class TestNames(Base):
    def test_java_names(self):
        mc.check_names(["Steve", "a_b_12"], False)
        for bad in ("has space", "x" * 17, "semi;colon"):
            with self.assertRaises(mc.UserError):
                mc.check_names([bad], False)

    def test_whitelist_commands(self):
        sent = []
        with mock.patch.object(mc, "rcon1", side_effect=lambda c: sent.append(c) or "ok"):
            mc.cmd_whitelist(["add", "Steve", "Alex"])
            mc.ENV["MC_BEDROCK"] = "1"
            mc.cmd_whitelist(["add", "CoolGamer", "--bedrock"])
        self.assertEqual(sent, ["whitelist add Steve", "whitelist add Alex", 'fwhitelist add "CoolGamer"'])

    def test_bedrock_whitelist_needs_crossplay(self):
        mc.ENV["MC_BEDROCK"] = "0"
        with self.assertRaises(mc.UserError):
            mc.cmd_whitelist(["add", "CoolGamer", "--bedrock"])


class TestFirewall(Base):
    def rules(self, net, bedrock):
        mc.ENV.update(MC_NET=net, MC_BEDROCK="1" if bedrock else "0", MC_PORT="25565")
        calls = []
        with mock.patch.object(mc, "ufw", side_effect=lambda *a, **k: calls.append(a) or True), \
             mock.patch.object(mc, "ssh_port", return_value="2222"):
            mc.configure_firewall()
        return [c for c in calls if c[0] == "allow"]

    def test_tailscale_with_bedrock(self):
        self.assertEqual(self.rules("tailscale", True), [
            ("allow", "2222/tcp"),
            ("allow", "in", "on", "tailscale0", "to", "any", "port", "25565", "proto", "tcp"),
            ("allow", "in", "on", "tailscale0", "to", "any", "port", "19132", "proto", "udp")])

    def test_public_java_only(self):
        self.assertEqual(self.rules("public", False), [("allow", "2222/tcp"), ("allow", "25565/tcp")])

    def test_lan(self):
        r = self.rules("lan", False)
        self.assertEqual(len(r), 4)
        self.assertIn(("allow", "from", "192.168.0.0/16", "to", "any", "port", "25565", "proto", "tcp"), r)


class TestSetupScript(unittest.TestCase):
    """Cheap consistency checks on the bash side."""
    text = (ROOT / "mc-setup.sh").read_text()

    def test_service_uses_env_variables_the_helper_writes(self):
        written = set(re.findall(r'set_env\("(MC_[A-Z_]+)"', self.text)) | set(re.findall(r"^(MC_[A-Z_]+)=", self.text, re.M))
        used = set(re.findall(r"\\\$\{(MC_[A-Z_]+)\}", self.text))
        self.assertTrue(used, "no variables found in the unit file")
        self.assertLessEqual(used, written)

    def test_helper_commands_used_by_setup_exist(self):
        for sub in set(re.findall(r'"\$HELPER" (\w+)', self.text)):
            self.assertTrue(re.search(rf'cmd (==|in) [^\n]*"{sub}"', self.text), f"helper has no '{sub}' command")


if __name__ == "__main__":
    unittest.main()
