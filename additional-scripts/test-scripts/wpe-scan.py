#!/usr/bin/env python3
"""
Wallpaper Engine workshop browser + unsupported-item scanner (linux-wallpaperengine)

A desktop GUI that lets you
  * browse every installed workshop item with thumbnails, back and forth
  * search live by workshop ID, part of an ID, name, tag, or pasted Steam URL
  * see each item's preview image, details and description
  * preview any item on your monitor, or test it for "Unsupported ..." errors
  * mark each wallpaper Keep / Ignore, and filter by Kept / Ignored 
  * scan everything (results -> wpe-unsupported.txt, same format as the old script);
    ignored items are skipped
  * kills leftover linux-wallpaperengine (and wpe*.sh) processes like the old script did:
    on scan start/end, on quit, on Ctrl+C / SIGTERM, and via the "Kill all WPE" button

Requirements:  python3, tkinter, Pillow
  Debian/Ubuntu:  sudo apt install python3-tk python3-pil
  Arch:           sudo pacman -S tk python-pillow
  pip:            pip install pillow

Usage:
  python3 wpe-scan.py [MONITOR]            e.g. python3 wpe-scan.py HDMI-A-1
  python3 wpe-scan.py [MONITOR] --scan     headless full scan, no GUI (old behaviour)
Settings (paths, monitor, scaling, ...) are editable in the GUI and saved to
~/.config/wpe-browser/config.json
"""
from __future__ import annotations

import argparse
import atexit
import collections
import dataclasses
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import webbrowser
from dataclasses import asdict, dataclass, field
from pathlib import Path

try:
    from PIL import Image, ImageTk
except ImportError:
    sys.exit("Pillow is required:  pip install pillow   (Arch: python-pillow, Debian: python3-pil)")

APP = "wpe-browser"
CONFIG_PATH = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / APP / "config.json"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / APP
THUMB = (96, 54)
PREVIEW_NAMES = ("preview.gif", "preview.jpg", "preview.jpeg", "preview.png", "preview.webp")

# ----------------------------------------------------------------------------- config


@dataclass
class Config:
    workshop: str = str(Path.home() / "Games/steamapps/workshop/content/431960")
    assets: str = str(Path.home() / "Games/steamapps/common/wallpaper_engine/assets")
    monitor: str = "HDMI-A-1"
    seconds: int = 6
    fps: int = 30
    scaling: str = "fit"          # fit | fill | stretch | default
    silent: bool = True
    settings_dir: str = str(Path.home() / ".config/mango/scripts/wpe-settings")
    animation: bool = True        # off = preview process is frozen (SIGSTOP) after a still frame is drawn
    freeze_delay: float = 3.0     # seconds to let the first frame render before freezing
    volume: int = 15
    clamp: str = "default"        # default | clamp | border | repeat
    particles: bool = True
    parallax: bool = True
    mouse: bool = True
    hwdec: str = "auto"           # auto | nvdec-copy | no
    audio_processing: bool = True
    auto_preview: bool = False
    list_open: bool = True         # left workshop list shown
    auto_advance: bool = True      # jump to next item after Keep/Ignore
    skip_ignored: bool = True      # scans skip ignored items
    kill_scripts: bool = True      # also kill leftover wpe*.sh scripts when cleaning up
    out: str = str(Path.cwd() / "wpe-unsupported.txt")
    ignored: list[str] = field(default_factory=list)

    @classmethod
    def load(cls) -> "Config":
        cfg = cls()
        try:
            data = json.loads(CONFIG_PATH.read_text())
            for k, v in data.items():
                if hasattr(cfg, k):
                    setattr(cfg, k, v)
        except Exception:
            pass
        if cfg.fps <= 0:
            cfg.fps = 30
        cfg.animation = True        # per-wallpaper only (<id>.conf / global.conf); never a global app default
        return cfg

    def save(self) -> None:
        try:
            CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            CONFIG_PATH.write_text(json.dumps(asdict(self), indent=2))
        except Exception:
            pass


# ----------------------------------------------------------------------------- data


@dataclass
class Item:
    id: str
    title: str
    type: str
    folder: Path
    preview: Path | None
    desc: str
    tags: list[str] = field(default_factory=list)
    search: str = ""


def folder_size(p: Path) -> int:
    total = 0
    for root, _dirs, files in os.walk(p):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def human_size(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GB"


VIDEO_EXT = {".mp4", ".webm", ".mkv", ".mov", ".avi", ".m4v", ".wmv"}


def infer_type(data: dict, folder: Path) -> str:
    """project.json sometimes lacks 'type' - guess from the entry file / folder contents."""
    t = str(data.get("type") or "").strip().lower()
    if t:
        return t
    ext = Path(str(data.get("file") or "")).suffix.lower()
    if ext in VIDEO_EXT:
        return "video"
    if ext in (".html", ".htm"):
        return "web"
    if ext == ".exe":
        return "application"
    if ext == ".json":
        return "scene"
    try:
        for p in folder.iterdir():
            s = p.suffix.lower()
            if s == ".pkg":
                return "scene"
            if s in VIDEO_EXT:
                return "video"
            if p.name.lower() == "index.html":
                return "web"
    except OSError:
        pass
    return "unknown"


def read_item(folder: Path) -> Item:
    data: dict = {}
    pj = folder / "project.json"
    try:
        raw = pj.read_text(encoding="utf-8-sig", errors="replace")
        try:
            d = json.loads(raw)
            data = {str(k).lower(): v for k, v in d.items()} if isinstance(d, dict) else {}
        except Exception:
            m = re.search(r'"title"\s*:\s*"([^"]*)"', raw, re.I)
            t = re.search(r'"type"\s*:\s*"([^"]*)"', raw, re.I)
            data = {"title": m.group(1) if m else "", "type": t.group(1) if t else ""}
    except OSError:
        pass
    title = str(data.get("title") or "(no title)")
    typ = infer_type(data, folder)
    tags = [str(t) for t in (data.get("tags") or []) if isinstance(t, (str, int))]
    desc = str(data.get("description") or "")
    preview = None
    for name in [data.get("preview"), *PREVIEW_NAMES]:
        if name and (folder / str(name)).is_file():
            preview = folder / str(name)
            break
    if preview is None:
        for p in sorted(folder.glob("preview.*")):
            preview = p
            break
    it = Item(folder.name, title, typ, folder, preview, desc, tags)
    it.search = f"{it.id} {title} {typ} {' '.join(tags)}".lower()
    return it


def load_items(workshop: str) -> list[Item]:
    root = Path(workshop)
    if not root.is_dir():
        return []
    folders = [d for d in root.iterdir() if d.is_dir() and d.name.isdigit()]
    folders.sort(key=lambda d: int(d.name))
    return [read_item(d) for d in folders]


class Results:
    """wpe-unsupported.txt:  id <TAB> title <TAB> message  (same as the old script)."""

    def __init__(self, path: str):
        self.path = Path(path)
        self.flagged: dict[str, str] = {}
        self.load()

    def load(self) -> None:
        self.flagged = {}
        try:
            for line in self.path.read_text(errors="replace").splitlines():
                parts = line.split("\t", 2)
                if parts and parts[0].isdigit():
                    self.flagged[parts[0]] = parts[2] if len(parts) > 2 else ""
        except OSError:
            pass

    def reset(self) -> None:
        self.flagged = {}
        try:
            self.path.write_text("")
        except OSError:
            pass

    def add(self, item: Item, line: str) -> bool:
        if item.id in self.flagged:
            return False
        self.flagged[item.id] = line
        try:
            with self.path.open("a") as f:
                f.write(f"{item.id}\t{item.title}\t{line}\n")
        except OSError:
            pass
        return True


class Review:
    """Per-wallpaper decision: 'keep' / 'ignore' / undecided, plus which items were previewed."""

    def __init__(self) -> None:
        self.path = CONFIG_PATH.parent / "review.json"
        # plain ID list the shell scripts read (wpe-lib.sh: wpe_is_mobile)
        self.mobile_file = Path(os.environ.get("WPE_MOBILE_FILE",
                                               Path.home() / ".config/mango/wpe-mobile.txt"))
        self.kept_file = Path(os.environ.get("WPE_KEPT_FILE",
                                             Path.home() / ".config/mango/wpe-kept.txt"))
        self.status: dict[str, str] = {}
        self.mobile: set[str] = set()          # independent of keep/ignore: "this one is for mobile"
        try:
            data = json.loads(self.path.read_text())
            self.status = {k: v for k, v in data.get("status", {}).items() if v in ("keep", "ignore")}
            self.mobile = set(data.get("mobile", []))
        except Exception:
            pass
        self.write_mobile_file()            # make sure the shell scripts see already-flagged items

    def write_mobile_file(self) -> None:
        """Plain ID lists for the shell scripts: wpe-mobile.txt and wpe-kept.txt."""
        kept = sorted((k for k, v in self.status.items() if v == "keep"), key=int)
        for path, ids, what in ((self.mobile_file, sorted(self.mobile, key=int), "kept for mobile"),
                                (self.kept_file, kept, "marked Keep")):
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"# written by wpe-scan.py: wallpapers {what}\n" + "".join(f"{i}\n" for i in ids))
            except OSError:
                pass

    def save(self) -> None:
        self.write_mobile_file()
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps({"status": self.status, "mobile": sorted(self.mobile, key=int)}))
            tmp.replace(self.path)
        except OSError:
            pass

    def get(self, iid: str) -> str | None:
        return self.status.get(iid)

    def set(self, iid: str, state: str | None) -> None:
        if state:
            self.status[iid] = state
        else:
            self.status.pop(iid, None)
        self.save()

    def is_mobile(self, iid: str) -> bool:
        return iid in self.mobile

    def set_mobile(self, iid: str, on: bool) -> None:
        if on:
            self.mobile.add(iid)
        else:
            self.mobile.discard(iid)
        self.save()

    def reset_all(self) -> tuple[int, int, int]:
        """Drop every Keep / Ignore mark and every mobile tag. The 'previewed' history is kept.
        Returns how many (kept, ignored, mobile) entries were cleared."""
        kept = sum(1 for v in self.status.values() if v == "keep")
        ign = sum(1 for v in self.status.values() if v == "ignore")
        mob = len(self.mobile)
        self.status.clear()
        self.mobile.clear()
        self.save()                         # also rewrites wpe-kept.txt / wpe-mobile.txt (now empty)
        return kept, ign, mob

# ----------------------------------------------------------------------------- wallpaper engine


def detect_monitors() -> list[str]:
    """Best-effort list of output names (Hyprland, Sway, wlr-randr, xrandr)."""
    probes = (
        (["hyprctl", "monitors", "-j"], lambda o: [m["name"] for m in json.loads(o)]),
        (["swaymsg", "-t", "get_outputs", "-r"], lambda o: [m["name"] for m in json.loads(o)]),
        (["wlr-randr", "--json"], lambda o: [m["name"] for m in json.loads(o)]),
        (["xrandr", "--listmonitors"],
         lambda o: [l.split()[-1] for l in o.splitlines()[1:] if l.strip()]),
    )
    for cmd, parse in probes:
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
            if r.returncode == 0:
                names = [n for n in parse(r.stdout) if n]
                if names:
                    return names
        except Exception:
            continue
    return []


# --- per-wallpaper config files (~/.config/mango/scripts/wpe-settings) -------------------
# global.conf        applies to every wallpaper
# <workshop id>.conf applies to that wallpaper only and wins over global.conf
# A setting changed in this app's menu is written to that wallpaper's <id>.conf only.
# global.conf is never written by this app.
# Format: key=value per line ('#' comments). Keys use the CLI flag names with underscores:
#   fps, scaling, clamp, hwdec, volume, silent, disable_particles, disable_parallax,
#   disable_mouse, no_audio_processing, ...  (boolean: 1/0, true/false, yes/no, on/off)
# Any other key is passed straight through as --key-name [value].
_CONF_MAP = {            # file key -> (Config attribute, kind)   kind: int | str | bool | inv
    "fps": ("fps", "int"), "volume": ("volume", "int"),
    "scaling": ("scaling", "str"), "clamp": ("clamp", "str"), "hwdec": ("hwdec", "str"),
    "silent": ("silent", "bool"),
    "disable_particles": ("particles", "inv"), "disable_parallax": ("parallax", "inv"),
    "disable_mouse": ("mouse", "inv"), "no_audio_processing": ("audio_processing", "inv"),
    "animation": ("animation", "bool"),
}
_CONF_BLOCKED = {"assets_dir", "screen_root", "bg", "window", "screen_span", "playlist", "silent_flag",
                 "layer", "help", "list_properties", "dump_structure", "screenshot"}
_TRUE = {"1", "true", "yes", "on", "y"}
_FALSE = {"0", "false", "no", "off", "n", ""}


def _read_conf(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line or line.startswith(("#", ";")) or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip().lower().lstrip("-").replace("-", "_")
            v = v.strip().strip("\"'")
            if k:
                out[k] = v
    except OSError:
        pass
    return out


def id_conf_path(cfg: Config, wid: str) -> Path:
    return Path(cfg.settings_dir) / f"{wid}.conf"


def conf_overrides(cfg: Config, wid: str, which: str = "both") -> tuple[dict, list[str]]:
    """(Config attribute -> value, extra CLI args) from global.conf and/or <wid>.conf."""
    d = Path(cfg.settings_dir)
    raw: dict[str, str] = {}
    if which in ("both", "global"):
        raw.update(_read_conf(d / "global.conf"))
    if which in ("both", "id") and wid.isdigit():
        raw.update(_read_conf(id_conf_path(cfg, wid)))
    over: dict = {}
    extra: list[str] = []
    for k, v in raw.items():
        if k in _CONF_MAP:
            attr, kind = _CONF_MAP[k]
            try:
                if kind == "int":
                    over[attr] = int(float(v))
                elif kind == "str":
                    over[attr] = v
                else:
                    b = v.lower() in _TRUE
                    if v.lower() not in _TRUE and v.lower() not in _FALSE:
                        continue
                    over[attr] = (not b) if kind == "inv" else b
            except ValueError:
                continue
        elif k not in _CONF_BLOCKED:
            flag = "--" + k.replace("_", "-")
            if v.lower() in _TRUE:
                extra.append(flag)
            elif v.lower() in _FALSE:
                continue
            else:
                extra += [flag, v]
    return over, extra


_ATTR_TO_KEY = {attr: (k, kind) for k, (attr, kind) in _CONF_MAP.items()}

def write_id_conf(cfg: Config, wid: str, attr: str, value) -> Path:
    """Set one setting in <wid>.conf (created if needed); other lines/comments are kept.
    Never touches global.conf."""
    if not wid.isdigit():
        raise ValueError("no wallpaper selected")
    key, kind = _ATTR_TO_KEY[attr]
    if kind == "inv":
        text = "0" if value else "1"
    elif kind == "bool":
        text = "1" if value else "0"
    else:
        text = str(value)
    path = id_conf_path(cfg, wid)
    lines = []
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        pass
    done = False
    for i, line in enumerate(lines):
        st = line.strip()
        if st and not st.startswith(("#", ";")) and "=" in st:
            k = st.split("=", 1)[0].strip().lower().lstrip("-").replace("-", "_")
            if k == key:
                lines[i] = f"{key}={text}"
                done = True
    if not done:
        lines.append(f"{key}={text}")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".conf.tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.replace(path)
    return path


def effective(cfg: Config, wid: str) -> tuple[Config, list[str], dict]:
    over, extra = conf_overrides(cfg, wid)
    return dataclasses.replace(cfg, **over), extra, over


def wpe_cmd(cfg: Config, folder: Path, silent: bool) -> list[str]:
    cfg, extra, over = effective(cfg, folder.name)
    if "silent" in over:
        silent = cfg.silent
    cmd = ["linux-wallpaperengine", "--assets-dir", cfg.assets, "--fps", str(max(1, cfg.fps)),
           "--hwdec", cfg.hwdec]
    if silent:
        cmd.append("--silent")
    else:
        cmd += ["--volume", str(cfg.volume)]
    if not cfg.audio_processing:
        cmd.append("--no-audio-processing")
    if not cfg.particles:
        cmd.append("--disable-particles")
    if not cfg.parallax:
        cmd.append("--disable-parallax")
    if not cfg.mouse:
        cmd.append("--disable-mouse")
    cmd += extra
    cmd += ["--layer", "background"]
    if cfg.monitor.strip().lower() == "all":
        screens = detect_monitors() or ["HDMI-A-1"]
    else:
        screens = [cfg.monitor]
    for scr in screens:
        cmd += ["--screen-root", scr, "--scaling", cfg.scaling]
        if cfg.clamp != "default":
            cmd += ["--clamp", cfg.clamp]
        cmd += ["--bg", str(folder)]
    return cmd


def kill_proc(p: subprocess.Popen | None) -> None:
    if p is None:
        return
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            p.kill()
        except OSError:
            pass


WPE_PROC_PATTERN = "linux-wallpaperengine --assets-dir"
WPE_SCRIPT_PATTERN = r"(^|/)wpe[^/ ]*\.sh( |$)"


# Long-running helpers that must survive the browser's cleanup. Killing them (the old behaviour of the
# "wpe*.sh" pattern) left the cycle timer dead and nothing to relaunch the wallpapers after wake-up.
WPE_DAEMONS = ("wpe-resume-watch.sh", "wpe-autopause.sh", "wpe-cycle.sh", "wpe-trace.sh", "wpe-who.sh")
GUI_BUSY_FILE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "wpe-ws" / "gui-busy"


def set_gui_busy(on: bool) -> None:
    """While a preview / test / scan engine is running, the watchdog scripts (wpe-resume-watch.sh,
    wpe-cycle.sh) see this file and stay out of the way instead of replacing or killing our engine."""
    try:
        if on:
            GUI_BUSY_FILE.parent.mkdir(parents=True, exist_ok=True)
            GUI_BUSY_FILE.write_text(str(os.getpid()))
        else:
            GUI_BUSY_FILE.unlink(missing_ok=True)
    except OSError:
        pass


def kill_wpe(scripts: bool = True, daemons: bool = False) -> None:
    """Same cleanup the old script did: kill linux-wallpaperengine, plus leftover wpe*.sh scripts.
    The background helpers (WPE_DAEMONS) are only killed when daemons=True (the explicit Kill-all button)."""
    try:
        subprocess.run(["pkill", "-KILL", "-f", WPE_PROC_PATTERN], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass
    if not scripts:
        return
    try:
        out = subprocess.run(["pgrep", "-f", WPE_SCRIPT_PATTERN], capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return
    for tok in out.split():
        try:
            pid = int(tok)
            if pid == os.getpid():
                continue
            cmd = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
            if not daemons and any(d in cmd for d in WPE_DAEMONS):
                continue
            os.kill(pid, signal.SIGKILL)
        except (ValueError, OSError):
            pass


def check_item(cfg: Config, folder: Path, on_proc=None) -> str | None:
    """Play an item for cfg.seconds and return the first 'Unsupported' line, if any."""
    env = dict(os.environ, SDL_AUDIODRIVER="dummy")
    p = subprocess.Popen(wpe_cmd(cfg, folder, True), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, env=env, text=True, errors="replace",
                         start_new_session=True)
    if on_proc:
        on_proc(p)
    try:
        out, _ = p.communicate(timeout=cfg.seconds)
    except subprocess.TimeoutExpired:
        kill_proc(p)
        out, _ = p.communicate()
    for line in (out or "").splitlines():
        if "Unsupported" in line:
            return line.strip()
    return None


# ----------------------------------------------------------------------------- thumbnails


def make_thumb(item: Item) -> Image.Image | None:
    if not item.preview:
        return None
    try:
        mtime = int(item.preview.stat().st_mtime)
        cache = CACHE_DIR / f"{item.id}_{mtime}.png"
        if cache.exists():
            im = Image.open(cache)
            im.load()
            return im.convert("RGB")
        im = Image.open(item.preview)
        im.seek(0)
        im = im.convert("RGB")
        im.thumbnail(THUMB)
        canvas = Image.new("RGB", THUMB, (34, 36, 46))
        canvas.paste(im, ((THUMB[0] - im.width) // 2, (THUMB[1] - im.height) // 2))
        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            canvas.save(cache)
        except OSError:
            pass
        return canvas
    except Exception:
        return None


def thumb_worker(todo: "queue.Queue[Item]", events: "queue.Queue", stop: threading.Event) -> None:
    while not stop.is_set():
        try:
            item = todo.get_nowait()
        except queue.Empty:
            return
        img = make_thumb(item)
        if img is not None:
            events.put(("thumb", item.id, img))


# ----------------------------------------------------------------------------- GUI
import tkinter as tk  # noqa: E402  (after Pillow check so the error message is friendlier)
from tkinter import filedialog, messagebox, ttk  # noqa: E402

BG, PANEL, FG, DIM = "#1b1c23", "#252733", "#e8e8ee", "#8b8fa3"
ACCENT, RED, GREEN, YELLOW = "#4f8cff", "#ff6b6b", "#5fd38d", "#f5c76b"


class Flow(ttk.Frame):
    """Row of widgets that wraps onto extra lines when the pane is too narrow,
    so no button ever ends up clipped off-screen."""

    def __init__(self, parent):
        super().__init__(parent)
        self.kids: list = []
        self._lastw = -1
        self.bind("<Configure>", self._on_conf)

    def add(self, w, **kw):
        self.kids.append(w)
        w.bind("<Configure>", lambda e: self._soon(), add="+")   # child text changed -> new width
        self._layout(force=True)
        return w

    def _soon(self) -> None:
        sig = tuple((w.winfo_reqwidth(), w.winfo_reqheight()) for w in self.kids)
        if sig != getattr(self, "_sig", None):
            self._sig = sig
            self.after_idle(self._layout)

    def _on_conf(self, e) -> None:
        if e.width != self._lastw:
            self._layout()

    def _layout(self, force: bool = False) -> None:
        width = self.winfo_width()
        if width < 50:                      # not mapped yet: assume one wide row
            width = 10 ** 6
        self._lastw = self.winfo_width()
        self._sig = tuple((w.winfo_reqwidth(), w.winfo_reqheight()) for w in self.kids)
        x = y = rowh = 0
        for w in self.kids:
            rw, rh = w.winfo_reqwidth(), w.winfo_reqheight()
            if x and x + rw > width:        # wrap
                y += rowh + 4
                x = rowh = 0
            w.place(x=x, y=y)
            x += rw + 6
            rowh = max(rowh, rh)
        self.configure(height=max(1, y + rowh + 2))


def setup_style(root: tk.Tk) -> None:
    s = ttk.Style(root)
    s.theme_use("clam")
    root.configure(bg=BG)
    root.option_add("*TCombobox*Listbox.background", PANEL)
    root.option_add("*TCombobox*Listbox.foreground", FG)
    root.option_add("*TCombobox*Listbox.selectBackground", ACCENT)
    s.configure(".", background=BG, foreground=FG, fieldbackground=PANEL, bordercolor=PANEL,
                lightcolor=PANEL, darkcolor=PANEL, troughcolor=BG, focuscolor=BG)
    s.configure("TFrame", background=BG)
    s.configure("Panel.TFrame", background=PANEL)
    s.configure("TLabel", background=BG, foreground=FG)
    s.configure("Dim.TLabel", foreground=DIM)
    s.configure("Panel.TLabel", background=PANEL, foreground=FG)
    s.configure("PanelDim.TLabel", background=PANEL, foreground=DIM)
    s.configure("Panel.TCheckbutton", background=PANEL, foreground=FG)
    s.map("Panel.TCheckbutton", background=[("active", PANEL)])
    s.configure("Title.TLabel", font=("TkDefaultFont", 13, "bold"))
    s.configure("TButton", background=PANEL, foreground=FG, padding=(10, 5), borderwidth=0)
    s.map("TButton", background=[("active", "#33364a"), ("disabled", BG)], foreground=[("disabled", DIM)])
    s.configure("TMenubutton", background=PANEL, foreground=FG, padding=(10, 5), borderwidth=0, arrowcolor=FG)
    s.map("TMenubutton", background=[("active", "#33364a")])
    s.configure("Accent.TButton", background=ACCENT, foreground="white")
    s.map("Accent.TButton", background=[("active", "#6a9fff"), ("disabled", PANEL)])
    s.configure("Red.TButton", background="#a8403c", foreground="white")
    s.map("Red.TButton", background=[("active", "#c9524d"), ("disabled", PANEL)])
    s.configure("Green.TButton", background="#2e9e5b", foreground="white")
    s.map("Green.TButton", background=[("active", "#3dbb72"), ("disabled", PANEL)])
    s.configure("TEntry", fieldbackground=PANEL, foreground=FG, insertcolor=FG, padding=5)
    s.configure("Search.TEntry", fieldbackground="#0f1017", foreground=FG, insertcolor=FG, padding=6,
                bordercolor=ACCENT, lightcolor=ACCENT, darkcolor=ACCENT)
    s.configure("TCombobox", fieldbackground=PANEL, background=PANEL, foreground=FG, arrowcolor=FG)
    s.map("TCombobox", fieldbackground=[("readonly", PANEL)], foreground=[("readonly", FG)])
    s.configure("TCheckbutton", background=BG, foreground=FG)
    s.map("TCheckbutton", background=[("active", BG)])
    s.configure("TSpinbox", fieldbackground=PANEL, foreground=FG, arrowcolor=FG)
    s.configure("Treeview", background=PANEL, fieldbackground=PANEL, foreground=FG,
                rowheight=THUMB[1] + 8, borderwidth=0)
    s.map("Treeview", background=[("selected", "#34406b")], foreground=[("selected", "white")])
    s.configure("Treeview.Heading", background=BG, foreground=DIM, relief="flat")
    s.configure("TNotebook", background=BG, borderwidth=0)
    s.configure("TNotebook.Tab", background=BG, foreground=DIM, padding=(12, 5))
    s.map("TNotebook.Tab", background=[("selected", PANEL)], foreground=[("selected", FG)])
    s.configure("TProgressbar", background=ACCENT, troughcolor=PANEL)
    s.configure("Vertical.TScrollbar", background=PANEL, arrowcolor=DIM)
    s.configure("TPanedwindow", background=BG)


class App:
    def __init__(self, root: tk.Tk, cfg: Config):
        self.root, self.cfg = root, cfg
        self.events: queue.Queue = queue.Queue()
        self.items: list[Item] = []
        self.by_id: dict[str, Item] = {}
        self.visible: list[Item] = []
        self.results = Results(cfg.out)
        self.review = Review()
        self.thumbs: dict[str, ImageTk.PhotoImage] = {}
        self.placeholder = ImageTk.PhotoImage(Image.new("RGB", THUMB, (34, 36, 46)))
        self.thumb_stop = threading.Event()
        self.play_proc: subprocess.Popen | None = None
        self.play_id: str | None = None
        self.play_log: collections.deque[str] = collections.deque(maxlen=300)
        self.scan_proc: subprocess.Popen | None = None
        self.cur: Item | None = None
        self.cur_pil: Image.Image | None = None
        self.big_photo: ImageTk.PhotoImage | None = None
        self.testing = False
        self.frozen = False
        self.quitting = False
        self._busy = False
        self.deleting = False
        self.scan_dialog: ScanDialog | None = None
        self._search_job = self._auto_job = self._resize_job = self._cfg_job = None

        root.title("Wallpaper Engine · Workshop Browser")
        root.geometry("1280x800")
        root.minsize(520, 400)
        self._build_menu()
        self._build_ui()
        self._build_context_menu()
        self._bind_keys()
        root.protocol("WM_DELETE_WINDOW", self.quit)
        self.set_status("Loading workshop items…")
        self.reload()
        self.root.after(40, self._pump)

    # ---------------------------------------------------------------- layout
    def _build_menu(self) -> None:
        m = tk.Menu(self.root, bg=PANEL, fg=FG, activebackground=ACCENT, bd=0)
        f = tk.Menu(m, tearoff=0, bg=PANEL, fg=FG, activebackground=ACCENT)
        f.add_command(label="Scan everything for unsupported items…", command=self.start_scan)
        f.add_command(label="Kill all linux-wallpaperengine / wpe*.sh now", command=self.kill_all)
        f.add_separator()
        f.add_command(label="Export keep / ignore lists", command=self.export_lists)
        f.add_command(label="Delete folders of all Ignored items…", command=self.delete_ignored_folders)
        f.add_command(label="Reset all marks (keep / ignore / mobile)…", command=self.reset_marks)
        f.add_command(label="Open results file", command=self.open_results)
        f.add_command(label="Reload workshop", command=self.reload)
        f.add_command(label="Paths…", command=lambda: PathsDialog(self))
        f.add_separator()
        f.add_command(label="Quit", command=self.quit, accelerator="Ctrl+Q")
        m.add_cascade(label="File", menu=f)
        self.root.config(menu=m)

    def _build_toolbar(self) -> None:
        c = self.cfg
        self.mon_var = tk.StringVar(value=c.monitor)
        self.scale_var = tk.StringVar(value=c.scaling)
        self.secs_var = tk.StringVar(value=str(c.seconds))
        self.fps_var = tk.StringVar(value=str(c.fps))
        self.anim_var = tk.BooleanVar(value=c.animation)
        self.mute_var = tk.BooleanVar(value=c.silent)
        self.vol_var = tk.StringVar(value=str(c.volume))
        self.clamp_var = tk.StringVar(value=c.clamp)
        self.part_var = tk.BooleanVar(value=c.particles)
        self.para_var = tk.BooleanVar(value=c.parallax)
        self.mouse_var = tk.BooleanVar(value=c.mouse)
        self.hwdec_var = tk.StringVar(value=c.hwdec)
        self.aproc_var = tk.BooleanVar(value=c.audio_processing)
        self.auto_var = tk.BooleanVar(value=c.auto_preview)
        self.adv_var = tk.BooleanVar(value=c.auto_advance)
        self.skip_var = tk.BooleanVar(value=c.skip_ignored)
        self.killsh_var = tk.BooleanVar(value=c.kill_scripts)

        # top bar: list toggle + search (always visible, above everything) + global actions
        self.list_open = bool(c.list_open)
        self.narrow = False
        self._sash_pending = False
        bar = ttk.Frame(self.root, style="Panel.TFrame", padding=(8, 5))
        bar.pack(fill="x", padx=8, pady=(8, 0))
        ttk.Button(bar, text="☠ Kill all WPE", command=self.kill_all).pack(side="right", padx=(6, 0))
        ttk.Button(bar, text="↺ Reset marks", style="Red.TButton",
                   command=self.reset_marks).pack(side="right", padx=(6, 0))
        ttk.Button(bar, text="⚙ Paths…", command=lambda: PathsDialog(self)).pack(side="right", padx=(6, 0))
        self.btn_list = ttk.Button(bar, text="☰ List", command=self.toggle_list)
        self.btn_list.pack(side="left")
        ttk.Label(bar, text="Search", style="PanelDim.TLabel").pack(side="left", padx=(10, 4))
        self.search_var = tk.StringVar()
        self.search = ttk.Entry(bar, textvariable=self.search_var, style="Search.TEntry")
        self.search.pack(side="left", fill="x", expand=True)
        ttk.Button(bar, text="Clear",  command=lambda: self.search_var.set("")).pack(side="left", padx=(4, 0))
        self.search_var.trace_add("write", lambda *_: self._on_search_typed())

        self._syncing = False
        # settings that .conf files can default; a change made in the menu becomes a session override
        self._attr_vars = {
            "fps": (self.fps_var, "int"), "volume": (self.vol_var, "int"),
            "scaling": (self.scale_var, "str"), "clamp": (self.clamp_var, "str"),
            "hwdec": (self.hwdec_var, "str"), "silent": (self.mute_var, "bool"),
            "particles": (self.part_var, "bool"), "parallax": (self.para_var, "bool"),
            "mouse": (self.mouse_var, "bool"), "audio_processing": (self.aproc_var, "bool"),
            "animation": (self.anim_var, "bool")}
        for attr, (v, _k) in self._attr_vars.items():
            v.trace_add("write", lambda *_, a=attr: self._var_changed(a))
        self._pending_restart = False
        self.mon_var.trace_add("write", lambda *_: self._restart_changed())
        for v in (self.secs_var, self.auto_var, self.adv_var, self.skip_var, self.killsh_var):
            v.trace_add("write", lambda *_: self._cfg_changed())

    def open_settings(self) -> None:
        """Pop up the settings menu right under the Change Setting button."""
        try:
            m = tk.Menu(self.root, tearoff=0, bg=PANEL, fg=FG, activebackground=ACCENT,
                        activeforeground="white", selectcolor=GREEN, bd=0)

            self._sync_vars()
            _e, _x, over = effective(self.cfg, self.cur.id if self.cur else "")
            wid = self.cur.id if self.cur else ""
            g_over, _x2 = conf_overrides(self.cfg, wid, "global")
            i_over, _x3 = conf_overrides(self.cfg, wid, "id")
            has_id_conf = bool(wid) and id_conf_path(self.cfg, wid).exists()

            def sub_menu():
                return tk.Menu(m, tearoff=0, bg=PANEL, fg=FG, activebackground=ACCENT,
                               activeforeground="white", selectcolor=GREEN)

            def head(label, attr, shown):
                tag = "  (this wallpaper)" if attr in i_over else "  (global)" if attr in g_over else ""
                return f"{label}: {shown}{tag}"

            def radio(label, attr, var, values):
                sub = sub_menu()
                for v in values:
                    sub.add_radiobutton(label=str(v), variable=var, value=str(v))
                m.add_cascade(label=head(label, attr, var.get()), menu=sub)

            def onoff(label, attr, var):
                sub = sub_menu()
                sub.add_radiobutton(label="on", variable=var, value=True)
                sub.add_radiobutton(label="off", variable=var, value=False)
                m.add_cascade(label=head(label, attr, "on" if var.get() else "off"), menu=sub)

            onoff("Animation", "animation", self.anim_var)
            radio("FPS", "fps", self.fps_var, [15, 24, 30, 45, 60, 90, 120, 144, 165, 240])
            radio("Scaling", "scaling", self.scale_var, ["fit", "fill", "stretch", "default"])
            radio("Clamp", "clamp", self.clamp_var, ["default", "clamp", "border", "repeat"])
            onoff("Particles", "particles", self.part_var)
            onoff("Parallax", "parallax", self.para_var)
            onoff("Mouse", "mouse", self.mouse_var)
            sub = sub_menu()
            sub.add_radiobutton(label="muted", variable=self.mute_var, value=True)
            sub.add_radiobutton(label="on", variable=self.mute_var, value=False)
            m.add_cascade(label=head("Audio muted", "silent", "yes" if self.mute_var.get() else "no"), menu=sub)
            radio("Volume", "volume", self.vol_var, [5, 10, 15, 25, 50, 75, 100])
            radio("Hwdec", "hwdec", self.hwdec_var, ["auto", "nvdec-copy", "no"])
            onoff("Audio processing", "audio_processing", self.aproc_var)
            radio("Seconds / item", "seconds_x", self.secs_var, [3, 4, 5, 6, 8, 10, 15, 20, 30, 60])
            m.add_separator()
            m.add_command(label="Delete this wallpaper's .conf (back to global)",
                          command=self.reset_overrides, state="normal" if has_id_conf else "disabled")
            m.add_separator()
            for text, var in (("Auto-preview on select", self.auto_var),
                              ("Auto-advance after Keep/Ignore", self.adv_var),
                              ("Skip ignored when scanning", self.skip_var),
                              ("Also kill wpe*.sh on cleanup", self.killsh_var)):
                m.add_checkbutton(label=text, variable=var)
            btn = self.btn_settings
            x, y = btn.winfo_rootx(), btn.winfo_rooty() + btn.winfo_height()
            # close any menu that is still open, then show this one
            prev = getattr(self, "_settings_menu", None)
            if prev is not None:
                try:
                    prev.unpost()
                except tk.TclError:
                    pass
            self._settings_menu = m
            ids: list[tuple[str, str]] = []

            def close(_e=None):
                try:
                    m.unpost()
                    m.grab_release()
                except tk.TclError:
                    pass
                for seq, fid in ids:
                    try:
                        self.root.unbind(seq, fid)
                    except tk.TclError:
                        pass
                ids.clear()

            # Tk menus on some Linux window managers / Wayland don't get a pointer grab, so a
            # click elsewhere never dismisses them. Dismiss explicitly on any outside click,
            # on Escape, or when the window loses focus / moves.
            for seq in ("<ButtonPress>", "<Escape>", "<Configure>"):
                ids.append((seq, self.root.bind(seq, close, add="+")))
            m.bind("<Escape>", close)
            m.bind("<Unmap>", lambda e: close() if ids else None)
            try:
                m.tk_popup(x, y)
            finally:
                m.grab_release()
        except Exception as e:                     # noqa: BLE001
            import traceback
            traceback.print_exc()
            messagebox.showerror("Settings", f"Could not open settings:\n{e}")

    def _monitor_choices(self) -> list[str]:
        mons = detect_monitors()
        cur = self.mon_var.get().strip()
        if cur and cur.lower() != "all" and cur not in mons:
            mons.append(cur)
        return ["All", *mons]

    def _build_ui(self) -> None:
        self._build_toolbar()

        # ---- left: filters + list (shown / hidden with the ☰ List button)
        pw = self.pw = ttk.PanedWindow(self.root, orient="horizontal")
        pw.pack(fill="both", expand=True, padx=8, pady=(8, 0))
        left = self.left = ttk.Frame(pw)
        # (panes are added / removed by _layout_panes)
        fr = ttk.Frame(left)
        fr.pack(fill="x", pady=(0, 6))
        self.type_var = tk.StringVar(value="All")
        self.review_var = tk.StringVar(value="All")
        self.sort_var = tk.StringVar(value="Title A–Z")
        self.flag_var = tk.BooleanVar(value=False)
        for col, (caption, var, vals, width) in enumerate((
                ("Type", self.type_var, ["All"], 10),
                ("Review", self.review_var, ["All", "Kept", "Ignored", "Not previewed yet", "Mobile"], 17),
                ("Sort", self.sort_var, ["Title A–Z", "ID ↑", "ID ↓", "Type", "Flagged first"], 12))):
            ttk.Label(fr, text=caption, style="Dim.TLabel").grid(row=0, column=col, sticky="w", padx=(0, 6))
            cb = ttk.Combobox(fr, textvariable=var, state="readonly", width=width, values=vals)
            cb.grid(row=1, column=col, padx=(0, 6), sticky="w")
            cb.bind("<<ComboboxSelected>>", lambda e: self.apply_filter())
            if caption == "Type":
                self.type_cb = cb
        ttk.Checkbutton(fr, text="⚠ Flagged only", variable=self.flag_var,
                        command=self.apply_filter).grid(row=1, column=3, padx=6)

        tf = ttk.Frame(left)
        tf.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(tf, columns=("id", "type", "mark"), selectmode="browse")
        self.tree.heading("#0", text="Wallpaper", anchor="w")
        self.tree.heading("id", text="ID", anchor="w")
        self.tree.heading("type", text="Type", anchor="w")
        self.tree.heading("mark", text="Status", anchor="w")
        self.tree.column("#0", width=300, minwidth=180, stretch=True)
        self.tree.column("id", width=100, minwidth=90, stretch=False, anchor="w")
        self.tree.column("type", width=86, minwidth=70, stretch=False, anchor="w")
        self.tree.column("mark", width=74, minwidth=60, stretch=False, anchor="w")
        sb = ttk.Scrollbar(tf, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.tree.tag_configure("bad", foreground=RED)
        self.tree.tag_configure("playing", foreground=GREEN)
        self.tree.tag_configure("ignore", foreground=DIM)
        self.tree.tag_configure("keep", foreground="#8fb8ff")
        self.tree.bind("<<TreeviewSelect>>", self._on_select)
        self.tree.bind("<Double-1>", lambda e: self.start_preview())
        self.tree.bind("<ButtonRelease-1>", self._tree_clicked)
        pw.bind("<Configure>", self._layout_panes)
        self.root.after(30, self._layout_panes)

        # ---- right: image first, compact info, action buttons (always reachable).
        # Pack order = space priority: actions (bottom) and the preview image get their space
        # first; the optional details box is hidden until asked for, so the image never vanishes.
        right = self.right = ttk.Frame(pw)

        act = ttk.Frame(right)
        act.pack(side="bottom", fill="x", pady=(6, 0))
        f1 = Flow(act)
        f1.pack(fill="x")
        f1.add(ttk.Label(f1, text="On", style="Dim.TLabel"))
        self.mon_cb = ttk.Combobox(f1, textvariable=self.mon_var, state="readonly", width=10,
                                   values=self._monitor_choices(),
                                   postcommand=lambda: self.mon_cb.configure(values=self._monitor_choices()))
        f1.add(self.mon_cb)
        f1.add(ttk.Button(f1, text="◀ Prev", command=lambda: self.step(-1)))
        f1.add(ttk.Button(f1, text="Next ▶", command=lambda: self.step(1)))
        self.btn_play = f1.add(ttk.Button(f1, text="▶ Preview on monitor", style="Accent.TButton",
                                          command=self.start_preview))
        self.btn_stop = f1.add(ttk.Button(f1, text="■ Stop", command=self.stop_preview))
        self.btn_test = f1.add(ttk.Button(f1, text="Test item", command=self.test_item))

        f2 = Flow(act)
        f2.pack(fill="x")
        self.btn_keep = f2.add(ttk.Button(f2, text="✔ Keep  (K)", command=lambda: self.mark("keep")))
        self.btn_ignore = f2.add(ttk.Button(f2, text="✖ Ignore  (I)", command=lambda: self.mark("ignore")))
        f2.add(ttk.Button(f2, text="Clear mark  (U)", command=lambda: self.mark(None)))
        self.btn_mobile = f2.add(ttk.Button(f2, text="Keep for mobile  (M)", command=self.toggle_mobile))
        self.btn_delete = f2.add(ttk.Button(f2, text="🗑 Delete folder", style="Red.TButton",
                                            command=self.delete_current_folder))
        self.btn_settings = f2.add(ttk.Button(f2, text="Change Setting", style="Green.TButton",
                                              command=self.open_settings))
        more = ttk.Menubutton(f2, text="More")
        mm = tk.Menu(more, tearoff=0, bg=PANEL, fg=FG, activebackground=ACCENT)
        for label, cmd in (("Copy name", self.copy_name), ("Copy ID", self.copy_id),
                           ("Open folder", self.open_folder), ("Steam page", self.open_steam)):
            mm.add_command(label=label, command=cmd)
        more["menu"] = mm
        f2.add(more)
        self.btn_details = f2.add(ttk.Button(f2, text="▾ Details", command=self.toggle_details))

        # preview image: claims its space before the text blocks below it
        self.img_frame = tk.Frame(right, bg="#12131a", height=90)
        self.img_frame.pack(side="top", fill="both", expand=True)
        self.img_frame.pack_propagate(False)
        self.img_label = tk.Label(self.img_frame, bg="#12131a", fg=DIM, text="No item selected")
        self.img_label.pack(fill="both", expand=True)
        self.img_frame.bind("<Configure>", lambda e: self._debounce_render())

        info = ttk.Frame(right)
        info.pack(side="top", fill="x", pady=(8, 0))
        self.title_lbl = ttk.Label(info, text="", style="Title.TLabel", wraplength=560, justify="left")
        self.title_lbl.pack(anchor="w", fill="x")
        info.bind("<Configure>", lambda e: self.title_lbl.config(wraplength=max(160, e.width - 10)))
        facts = Flow(info)
        facts.pack(fill="x", pady=(2, 0))
        self.info_vals: dict[str, ttk.Label] = {}
        for key in ("ID", "Type", "Mark", "Status"):
            pair = ttk.Frame(facts)
            ttk.Label(pair, text=key, style="Dim.TLabel").pack(side="left", padx=(0, 5))
            lb = ttk.Label(pair, text="", wraplength=420, justify="left")
            lb.pack(side="left")
            self.info_vals[key] = lb
            facts.add(pair)

        # details: hidden by default (▾ Details button), tabs for description / folder+tags / log
        nb = self.details = ttk.Notebook(right)
        self.details_open = False
        self.desc_txt = self._make_text(nb)
        self.log_txt = self._make_text(nb)
        meta = ttk.Frame(nb, style="Panel.TFrame", padding=8)
        for r, key in enumerate(("Tags", "Folder")):
            ttk.Label(meta, text=key, style="PanelDim.TLabel", width=7).grid(row=r, column=0, sticky="nw")
            lb = ttk.Label(meta, text="", style="Panel.TLabel", wraplength=480, justify="left")
            lb.grid(row=r, column=1, sticky="w")
            self.info_vals[key] = lb
        nb.add(self.desc_txt.master, text="Description")
        nb.add(meta, text="Tags / folder")
        nb.add(self.log_txt.master, text="Preview log")

        bar = ttk.Frame(self.root)
        bar.pack(side="bottom", fill="x", padx=8, pady=6, before=pw)   # status bar keeps its space

        # inline confirmation bar (hidden until needed) - replaces modal messagebox for deletes
        self._confirm_cb = None
        cb = self.confirm_bar = ttk.Frame(self.root, style="Panel.TFrame", padding=(10, 8))
        self.confirm_lbl = ttk.Label(cb, style="Panel.TLabel", justify="left", wraplength=600)
        self.confirm_lbl.pack(side="left", fill="x", expand=True)
        self.confirm_no = ttk.Button(cb, text="Cancel (Esc)", command=self.confirm_cancel)
        self.confirm_no.pack(side="right", padx=(6, 0))
        self.confirm_yes = ttk.Button(cb, text="Delete", style="Red.TButton", command=self.confirm_accept)
        self.confirm_yes.pack(side="right")
        cb.bind("<Configure>", lambda e: self.confirm_lbl.config(wraplength=max(200, e.width - 300)))
        self.status_var = tk.StringVar()
        ttk.Label(bar, textvariable=self.status_var, style="Dim.TLabel").pack(side="left")
        self.count_var = tk.StringVar()
        ttk.Label(bar, textvariable=self.count_var, style="Dim.TLabel").pack(side="right")

    # ---------------------------------------------------------------- responsive panes
    def _layout_panes(self, _e=None) -> None:
        """Wide window: list (optional) beside the preview.  Narrow window: the list becomes a
        full-width drawer that replaces the preview while open and closes when you pick an item."""
        pw = self.pw
        w = pw.winfo_width()
        self.narrow = 1 < w < 780
        if self.narrow:
            want = (self.left,) if self.list_open else (self.right,)
        else:
            want = (self.left, self.right) if self.list_open else (self.right,)
        have = tuple(str(x) for x in pw.panes())
        if have != tuple(str(x) for x in want):
            for x in have:
                pw.forget(x)
            for x in want:
                pw.add(x, weight=1 if x is self.left else 2)
            self._sash_pending = len(want) == 2
        if self._sash_pending and w > 200:
            self._sash_pending = False
            self.root.after(40, self._set_sash)
        self.btn_list.config(text="☰ Hide list" if self.list_open else "☰ Show list")
        if self.list_open:
            self.root.after_idle(self._scroll_to_cur)

    def _set_sash(self, tries: int = 6) -> None:
        try:
            w = self.pw.winfo_width()
            if len(self.pw.panes()) != 2 or w <= 1:
                return
            self.pw.sashpos(0, max(340, min(560, int(w * 0.42))))
            if self.pw.sashpos(0) < 100 and tries > 0:       # layout not realised yet: retry
                self.root.after(60, lambda: self._set_sash(tries - 1))
        except tk.TclError:
            pass

    def _scroll_to_cur(self) -> None:
        if self.cur and self.tree.exists(self.cur.id):
            self.tree.see(self.cur.id)

    def _set_list(self, show: bool) -> None:
        if show != self.list_open:
            self.list_open = show
            self._layout_panes()

    def toggle_list(self) -> None:
        self._set_list(not self.list_open)
        if not self.narrow:
            self.cfg.list_open = self.list_open
            self.cfg.save()

    def _on_search_typed(self) -> None:
        if self.search_var.get().strip():          # searching opens the filtered list
            self._set_list(True)
        self._debounce_filter()

    def _tree_clicked(self, e) -> None:
        if self.narrow and self.list_open and self.tree.identify_row(e.y):
            self.root.after(60, lambda: self._set_list(False))   # drawer: pick an item, close

    def toggle_details(self) -> None:
        self.details_open = not self.details_open
        if self.details_open:
            self.details.pack(side="bottom", fill="x", pady=(6, 0), before=self.img_frame)
        else:
            self.details.pack_forget()
        self.btn_details.config(text="▴ Details" if self.details_open else "▾ Details")

    def _build_context_menu(self) -> None:
        m = tk.Menu(self.root, tearoff=0, bg=PANEL, fg=FG, activebackground=ACCENT)
        m.add_command(label="Preview on monitor", command=self.start_preview)
        m.add_command(label="Test item", command=self.test_item)
        m.add_separator()
        m.add_command(label="✔ Keep", command=lambda: self.mark("keep"))
        m.add_command(label="✖ Ignore", command=lambda: self.mark("ignore"))
        m.add_command(label="Clear mark", command=lambda: self.mark(None))
        m.add_command(label="Keep for mobile", command=self.toggle_mobile)
        m.add_separator()
        m.add_command(label="Copy name", command=self.copy_name)
        m.add_command(label="Copy ID", command=self.copy_id)
        m.add_command(label="Open folder", command=self.open_folder)
        m.add_separator()
        m.add_command(label="🗑 Delete folder from disk…", command=self.delete_current_folder)
        self.ctx = m
        self.tree.bind("<Button-3>", self._popup)

    def _popup(self, e) -> None:
        iid = self.tree.identify_row(e.y)
        if iid:
            self.tree.selection_set(iid)
            self.ctx.tk_popup(e.x_root, e.y_root)

    def _make_text(self, parent) -> tk.Text:
        fr = ttk.Frame(parent, style="Panel.TFrame")
        t = tk.Text(fr, bg=PANEL, fg=FG, bd=0, wrap="word", height=5, padx=8, pady=6,
                    insertbackground=FG, highlightthickness=0, state="disabled")
        sb = ttk.Scrollbar(fr, orient="vertical", command=t.yview)
        t.configure(yscrollcommand=sb.set)
        t.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        return t

    def _bind_keys(self) -> None:
        r = self.root
        r.bind_all("<Left>", lambda e: self._nav(e, -1))
        r.bind_all("<Right>", lambda e: self._nav(e, 1))
        r.bind_all("<Control-f>", lambda e: (self.search.focus_set(), self.search.select_range(0, "end")))
        r.bind_all("<Control-l>", lambda e: self.toggle_list())
        r.bind_all("<Control-q>", lambda e: self.quit())
        r.bind_all("<Escape>", self.confirm_cancel, add="+")
        r.bind_all("<Control-t>", lambda e: self.test_item())
        t = self.tree
        t.bind("<Return>", lambda e: ((self._set_list(False) if self.narrow else self.start_preview()), "break")[1])
        t.bind("<space>", lambda e: (self.toggle_preview(), "break")[1])
        t.bind("<Escape>", lambda e: self.stop_preview())
        # K / I / U work wherever focus is (list, buttons, ...) except while typing in a field
        for keys, state in (("kK", "keep"), ("iI", "ignore"), ("uU", None)):
            for ch in keys:
                r.bind_all(f"<KeyPress-{ch}>", lambda e, st=state: self._hotkey(st))
        for ch in "mM":
            r.bind_all(f"<KeyPress-{ch}>", lambda e: self._hotkey("mobile"))
        t.bind("<Delete>", lambda e: (self.mark(None), "break")[1])
        t.bind("<Control-c>", lambda e: (self.copy_name(), "break")[1])
        t.bind("<Control-Shift-C>", lambda e: (self.copy_id(), "break")[1])
        self.search.bind("<Escape>", lambda e: self.search_var.set(""))
        self.search.bind("<Down>", lambda e: (self._set_list(True), self.tree.focus_set(), "break")[2])
        self.search.bind("<Return>", lambda e: (self._set_list(True), self.tree.focus_set(), "break")[2])

    def _hotkey(self, state):
        f = self.root.focus_get()
        if f is None or f.winfo_toplevel() is not self.root:
            return None
        if isinstance(f, (tk.Entry, ttk.Entry, ttk.Combobox, tk.Text, ttk.Spinbox, tk.Spinbox)):
            return None
        self.toggle_mobile() if state == "mobile" else self.mark(state)
        return "break"

    def _nav(self, event, d: int):
        if isinstance(self.root.focus_get(), (tk.Entry, ttk.Entry, ttk.Combobox, tk.Text, ttk.Spinbox)):
            return None
        self.step(d)
        return "break"

    # ---------------------------------------------------------------- settings bar -> config
    def _var_changed(self, attr: str) -> None:
        if self._syncing:
            return
        var, kind = self._attr_vars[attr]
        try:
            val = {"int": lambda: int(var.get()), "str": var.get, "bool": var.get}[kind]()
        except (ValueError, tk.TclError):
            return
        if attr in ("fps", "volume") and val < (1 if attr == "fps" else 0):
            return
        if not self.cur:
            return
        try:
            path = write_id_conf(self.cfg, self.cur.id, attr, val)
        except (OSError, ValueError) as e:
            self.set_status(f"Could not write {self.cur.id}.conf: {e}")
            return
        self._pending_restart = True
        self._cfg_changed()
        self.set_status(f"Saved {attr} to {path.name} (global.conf untouched)")

    def _restart_changed(self) -> None:
        if not self._syncing:
            self._pending_restart = True
        self._cfg_changed()

    def _sync_vars(self) -> None:
        """Make the menu show what is really in effect for the selected wallpaper."""
        eff, _x, _o = effective(self.cfg, self.cur.id if self.cur else "")
        self._syncing = True
        try:
            for attr, (var, kind) in self._attr_vars.items():
                val = getattr(eff, attr)
                var.set(str(val) if kind == "int" else val)
        finally:
            self._syncing = False

    def reset_overrides(self) -> None:
        if not self.cur:
            return
        path = id_conf_path(self.cfg, self.cur.id)
        if not path.exists():
            return
        if not messagebox.askyesno("Delete .conf", f"Delete {path}?\nThis wallpaper will use global.conf again."):
            return
        try:
            path.unlink()
        except OSError as e:
            messagebox.showerror("Delete failed", str(e))
            return
        self._sync_vars()
        self._pending_restart = True
        self._cfg_changed()
        self.set_status(f"Deleted {path.name} — using global.conf again")

    def _cfg_changed(self) -> None:
        if self._cfg_job:
            self.root.after_cancel(self._cfg_job)
        self._cfg_job = self.root.after(300, self._apply_cfg)

    def _apply_cfg(self) -> None:
        c = self.cfg
        mon = self.mon_var.get().strip()
        if mon:
            c.monitor = mon
        try:
            v = int(self.secs_var.get())
            if v > 0:
                c.seconds = v
        except ValueError:
            pass
        c.auto_preview = self.auto_var.get()
        c.auto_advance, c.skip_ignored = self.adv_var.get(), self.skip_var.get()
        c.kill_scripts = self.killsh_var.get()
        c.save()
        if self._pending_restart:
            self._pending_restart = False
            if self._alive() and self.cur and self.play_id == self.cur.id:
                self.start_preview()
        self.set_status("Setting changed — applies to the next preview or test (.conf files untouched)")
        self._update_status_line()

    # ---------------------------------------------------------------- loading
    def reload(self) -> None:
        self.thumb_stop.set()
        self.stop_preview()
        self.results = Results(self.cfg.out)
        self.items, self.by_id, self.thumbs = [], {}, {}
        self.tree.delete(*self.tree.get_children())

        def work():
            self.events.put(("items", load_items(self.cfg.workshop)))
        threading.Thread(target=work, daemon=True).start()

    def _on_items(self, items: list[Item]) -> None:
        self.items = items
        self.by_id = {i.id: i for i in items}
        types = sorted({i.type for i in items})
        self.type_cb.configure(values=["All", *types])
        if self.type_var.get() not in ("All", *types):
            self.type_var.set("All")
        if not items:
            self.set_status(f"No workshop items found in {self.cfg.workshop} — check ⚙ Paths…")
        else:
            self.set_status(f"Loaded {len(items)} items. Loading thumbnails…")
        self.apply_filter()
        self.thumb_stop = threading.Event()
        todo: queue.Queue = queue.Queue()
        shown = set(i.id for i in self.visible)
        for it in self.visible:
            todo.put(it)
        for it in items:
            if it.id not in shown:
                todo.put(it)
        for _ in range(4):
            threading.Thread(target=thumb_worker, args=(todo, self.events, self.thumb_stop), daemon=True).start()

    # ---------------------------------------------------------------- filtering
    def _debounce_filter(self) -> None:
        if self._search_job:
            self.root.after_cancel(self._search_job)
        self._search_job = self.root.after(150, self.apply_filter)

    def _review_ok(self, it: Item, mode: str) -> bool:
        st = self.review.get(it.id)
        if mode == "Kept":
            return st == "keep"
        if mode == "Ignored":
            return st == "ignore"
        if mode == "Not previewed yet":
            return st is None and not self.review.is_mobile(it.id)
        if mode == "Mobile":
            return self.review.is_mobile(it.id)
        return True

    def _query(self) -> tuple[str, list[str]]:
        q = self.search_var.get().strip().lower()
        m = re.search(r"id=(\d+)", q)
        if m:
            q = m.group(1)
        return q, q.split()

    def _passes(self, it: Item) -> bool:
        """Would this item still be listed under the current search / filters?"""
        _q, terms = self._query()
        return ((self.type_var.get() in ("All", it.type))
                and self._review_ok(it, self.review_var.get())
                and (not self.flag_var.get() or it.id in self.results.flagged)
                and all(t in it.search for t in terms))

    def apply_filter(self, near: int | None = None) -> None:
        q, _terms = self._query()
        flagged = self.results.flagged
        res = [it for it in self.items if self._passes(it)]
        mode = self.sort_var.get()
        if mode == "Title A–Z":
            res.sort(key=lambda i: (i.title.lower(), int(i.id)))
        elif mode == "ID ↑":
            res.sort(key=lambda i: int(i.id))
        elif mode == "ID ↓":
            res.sort(key=lambda i: -int(i.id))
        elif mode == "Type":
            res.sort(key=lambda i: (i.type, i.title.lower()))
        elif mode == "Flagged first":
            res.sort(key=lambda i: (i.id not in flagged, i.title.lower()))
        if q.isdigit():                       # exact ID match always on top
            res.sort(key=lambda i: i.id != q)
        keep = self.cur.id if self.cur else None
        self.visible = res
        self.tree.delete(*self.tree.get_children())
        for it in res:
            self.tree.insert("", "end", iid=it.id, text="  " + it.title,
                             image=self.thumbs.get(it.id, self.placeholder),
                             values=self._row_values(it), tags=self._row_tags(it))
        self._update_counts()
        if keep and self.tree.exists(keep):
            target = keep
        elif res and near is not None:
            target = res[min(near, len(res) - 1)].id
        else:
            target = res[0].id if res else None
        if target:
            self.tree.selection_set(target)
            self.tree.see(target)
        else:
            self.cur = None
            self._show(None)

    def _update_counts(self) -> None:
        st = self.review.status
        kept = sum(1 for k, v in st.items() if v == "keep" and k in self.by_id)
        ign = sum(1 for k, v in st.items() if v == "ignore" and k in self.by_id)
        mob = sum(1 for k in self.review.mobile if k in self.by_id)
        self.count_var.set(f"{len(self.visible)} of {len(self.items)} shown · ✔ {kept} kept · "
                           f"✖ {ign} ignored · {mob} mobile · ⚠ {len(self.results.flagged)} flagged")

    def _glyphs(self, it: Item) -> str:
        g = ""
        if it.id == self.play_id and self._alive():
            g += "▶"
        if it.id in self.results.flagged:
            g += "⚠"
        if self.review.is_mobile(it.id):
            g += "M"
        return g + {"keep": "✔", "ignore": "✖"}.get(self.review.get(it.id) or "", "")

    def _row_values(self, it: Item):
        return (it.id, it.type, self._glyphs(it))

    def _row_tags(self, it: Item):
        if it.id in self.results.flagged:
            return ("bad",)
        if it.id == self.play_id and self._alive():
            return ("playing",)
        st = self.review.get(it.id)
        return (st,) if st else ()

    def _refresh_row(self, iid: str | None) -> None:
        if iid and self.tree.exists(iid):
            it = self.by_id[iid]
            self.tree.item(iid, values=self._row_values(it), tags=self._row_tags(it))

    # ---------------------------------------------------------------- review marks
    def mark(self, state: str | None) -> None:
        it = self.cur
        if not it:
            return
        new = None if state is not None and self.review.get(it.id) == state else state
        self.review.set(it.id, new)
        if new != "keep":                       # mobile only makes sense on kept items
            self.review.set_mobile(it.id, False)
        label = {"keep": "kept ✔", "ignore": "ignored ✖", None: "mark cleared"}[new]
        self._after_review_change(it, label, advance=bool(new))

    def toggle_mobile(self) -> None:
        """M = Keep + mobile in one go. Pressing M again on a mobile item drops only the mobile tag
        (it stays kept). Clearing / ignoring an item also removes its mobile tag."""
        it = self.cur
        if not it:
            return
        if self.review.is_mobile(it.id):
            self.review.set_mobile(it.id, False)
            self._after_review_change(it, "mobile tag removed (still kept ✔)", advance=False)
            return
        self.review.set(it.id, "keep")
        self.review.set_mobile(it.id, True)
        self._after_review_change(it, "kept ✔ + mobile", advance=True)

    def _after_review_change(self, it: Item, label: str, advance: bool) -> None:
        kids = list(self.tree.get_children())
        idx = kids.index(it.id) if it.id in kids else None

        if idx is None or self._passes(it):
            # still listed under the current filter: just refresh it, then optionally advance
            self._refresh_row(it.id)
            self._update_counts()
            if advance and self.adv_var.get():
                self.step(1)
            self._update_status_line()
        else:
            # The item left this filtered list (e.g. marked while on "Not previewed yet").
            # Drop only its row: the next wallpaper slides up into its place, so selecting
            # that same position IS "go to next" -- no extra step, nothing skipped.
            nxt = kids[idx + 1] if idx + 1 < len(kids) else (kids[idx - 1] if idx > 0 else None)
            self.visible = [v for v in self.visible if v.id != it.id]
            self.tree.delete(it.id)
            self._update_counts()
            if nxt:
                self.tree.selection_set(nxt)
                self.tree.see(nxt)
                self._on_select()
            else:
                self.cur = None
                self._show(None)
        self.set_status(f"{it.title}: {label}")

    def reset_marks(self) -> None:
        """Clear every Keep, Ignore and mobile mark (asks first, inline like the delete confirm)."""
        st = self.review.status
        kept = sum(1 for v in st.values() if v == "keep")
        ign = sum(1 for v in st.values() if v == "ignore")
        mob = len(self.review.mobile)
        if not (kept or ign or mob):
            self.set_status("Nothing to reset: no item is kept, ignored or marked mobile")
            return
        text = (f"Reset ALL marks?\n✔ {kept} kept · ✖ {ign} ignored · {mob} mobile will be cleared.\n"
                "Playlists that auto-add kept wallpapers will lose them. No folders are deleted. "
                "Cannot be undone.")
        self.ask_inline(text, "Reset all", self._run_reset)

    def _run_reset(self) -> None:
        kept, ign, mob = self.review.reset_all()
        self.apply_filter()                 # rows, glyphs, counts and any Keep/Ignore filter
        if self.cur:
            self._show(self.cur)            # refresh the Mark line of the open item
        self.set_status(f"Reset: cleared {kept} kept, {ign} ignored, {mob} mobile")

    # ---------------------------------------------------------------- delete from disk
    def _safe_folder(self, it: Item) -> Path | None:
        """The item's folder, but only if it really is <workshop>/<numeric id> -- never anything else."""
        try:
            if not it.id.isdigit() or it.folder.name != it.id:
                return None
            if it.folder.parent.resolve() != Path(self.cfg.workshop).resolve():
                return None
            return it.folder
        except OSError:
            return None

    def delete_current_folder(self) -> None:
        if self.cur:
            self.delete_folders([self.cur])

    def delete_ignored_folders(self) -> None:
        todo = [it for it in self.items if self.review.get(it.id) == "ignore"]
        if not todo:
            self.set_status("No item is marked Ignored")
            return
        self.delete_folders(todo)

    def delete_folders(self, items: list[Item]) -> None:
        """Delete the workshop folders of `items` from disk (Steam keeps them after unsubscribing)."""
        if self.quitting or self.deleting:
            return
        todo = [(it, f) for it in items if (f := self._safe_folder(it)) is not None and f.exists()]
        if not todo:
            self.set_status("Nothing to delete: the folder is already gone or is not inside the workshop folder")
            return
        note = "Cannot be undone. If you are still subscribed, Steam re-downloads it, so unsubscribe first."
        if len(todo) == 1:
            it, f = todo[0]
            text = f"Delete “{it.title}” from disk?\n{f}\n{note}"
            label = "Delete"
        else:
            names = ", ".join(it.title[:40] for it, _f in todo[:3])
            more = f" … +{len(todo) - 3} more" if len(todo) > 3 else ""
            text = f"Delete {len(todo)} wallpaper folders from disk?\n{names}{more}\n{note}"
            label = f"Delete {len(todo)}"
        # Inline confirmation bar instead of a modal messagebox: a modal Tk dialog grabs all
        # input, and if the window manager hides or misplaces it the whole app looks frozen.
        self.ask_inline(text, label, lambda: self._run_delete(todo))

    def ask_inline(self, text: str, yes_label: str, on_yes) -> None:
        self._confirm_cb = on_yes
        self.confirm_lbl.config(text=text)
        self.confirm_yes.config(text=yes_label)
        self.confirm_bar.pack(side="bottom", fill="x", padx=8, pady=(0, 4), before=self.pw)
        self.confirm_no.focus_set()

    def confirm_cancel(self, _e=None) -> None:
        if self._confirm_cb is None:
            return
        self._confirm_cb = None
        self.confirm_bar.pack_forget()
        self.set_status("Cancelled")
        self.tree.focus_set()

    def confirm_accept(self) -> None:
        cb, self._confirm_cb = self._confirm_cb, None
        self.confirm_bar.pack_forget()
        self.tree.focus_set()
        if cb:
            cb()

    def _run_delete(self, todo: list) -> None:
        if self.quitting or self.deleting:
            return
        if self.play_id in {it.id for it, _f in todo}:
            self.stop_preview()
        self.deleting = True
        self.btn_delete.state(["disabled"])
        self.set_status(f"Deleting {len(todo)} folder(s)…")

        def work():
            for it, f in todo:
                err = None
                try:
                    if f.is_symlink():
                        f.unlink()                  # only the link, never what it points to
                    else:
                        shutil.rmtree(f)
                except OSError as e:
                    err = str(e)
                self.events.put(("deleted", it.id, f.exists(), err))
            self.events.put(("delete_done",))
        threading.Thread(target=work, daemon=True).start()

    def _drop_items(self, ids: set[str]) -> None:
        """Forget deleted items and move the selection to the neighbour (next one first)."""
        if not ids:
            return
        cur_id = self.cur.id if self.cur else None
        kids = list(self.tree.get_children())
        nxt = None
        if cur_id in ids and cur_id in kids:
            i = kids.index(cur_id)
            for k in kids[i + 1:] + kids[:i][::-1]:
                if k not in ids:
                    nxt = k
                    break
        self.items = [i for i in self.items if i.id not in ids]
        self.visible = [v for v in self.visible if v.id not in ids]
        for iid in ids:
            self.by_id.pop(iid, None)
            self.thumbs.pop(iid, None)
            self.results.flagged.pop(iid, None)
            if self.tree.exists(iid):
                self.tree.delete(iid)
        self._update_counts()
        if cur_id in ids:
            if nxt:
                self.tree.selection_set(nxt)
                self.tree.see(nxt)
                self._on_select()
            else:
                self.cur = None
                self._show(None)

    def export_lists(self) -> None:
        d = Path(self.cfg.out).parent
        try:
            n = {}
            for state, fname in (("keep", "wpe-keep.txt"), ("ignore", "wpe-ignore.txt"),
                                 ("mobile", "wpe-mobile.txt")):
                rows = [it for it in self.items
                        if (self.review.is_mobile(it.id) if state == "mobile"
                            else self.review.get(it.id) == state)]
                (d / fname).write_text("".join(f"{it.id}\t{it.title}\n" for it in rows))
                n[state] = len(rows)
            self.set_status(f"Exported {n['keep']} kept → wpe-keep.txt, {n['ignore']} ignored → wpe-ignore.txt, "
                            f"{n['mobile']} mobile → wpe-mobile.txt in {d}")
        except OSError as e:
            messagebox.showerror("Export failed", str(e))

    # ---------------------------------------------------------------- selection / display
    def _on_select(self, _e=None) -> None:
        sel = self.tree.selection()
        if not sel:
            return
        item = self.by_id.get(sel[0])
        if item is self.cur:
            return
        self.cur = item
        self._show(item)
        if self.auto_var.get():
            if self._auto_job:
                self.root.after_cancel(self._auto_job)
            self._auto_job = self.root.after(450, self.start_preview)

    def step(self, d: int) -> None:
        kids = self.tree.get_children()
        if not kids:
            return
        sel = self.tree.selection()
        i = kids.index(sel[0]) if sel and sel[0] in kids else -1
        nxt = kids[(i + d) % len(kids)]
        self.tree.selection_set(nxt)
        self.tree.see(nxt)

    def _show(self, item: Item | None) -> None:
        if item is None:
            self.title_lbl.config(text="")
            for v in self.info_vals.values():
                v.config(text="")
            self.img_label.config(image="", text="No matches")
            self._set_text(self.desc_txt, "")
            self.btn_delete.state(["disabled"])
            return
        self.btn_delete.state(["!disabled"])
        self.title_lbl.config(text=item.title)
        self.info_vals["ID"].config(text=item.id)
        self.info_vals["Type"].config(text=item.type)
        self.info_vals["Tags"].config(text=", ".join(item.tags) or "—")
        self.info_vals["Folder"].config(text=str(item.folder))
        self._update_status_line()
        self._set_text(self.desc_txt, item.desc.strip() or "(no description)")
        self._refresh_log()
        self.cur_pil = None
        if item.preview:
            try:
                im = Image.open(item.preview)
                im.seek(0)
                self.cur_pil = im.convert("RGB")
            except Exception:
                self.cur_pil = None
        self._render_big()

    def _update_status_line(self) -> None:
        it = self.cur
        if not it:
            return
        if it.id in self.results.flagged:
            txt, col = f"⚠ {self.results.flagged[it.id]}", RED
        elif it.id == self.play_id and self._alive():
            txt, col = (f"❄ Frozen on {self.cfg.monitor} (animation off)" if self.frozen
                        else f"● Playing on {self.cfg.monitor}"), GREEN
        elif it.id == self.play_id:
            txt, col = "■ Preview process exited", YELLOW
        elif self.play_id and self._alive():
            txt, col = f"Another item is playing ({self.play_id})", DIM
        else:
            txt, col = "Not playing", DIM
        self.info_vals["Status"].config(text=txt, foreground=col)
        st = self.review.get(it.id)
        if st == "keep":
            mtxt, mcol = "✔ Kept", "#8fb8ff"
        elif st == "ignore":
            mtxt, mcol = "✖ Ignored", DIM
        else:
            mtxt = "Not decided"
            mcol = FG
        mob = self.review.is_mobile(it.id)
        self.info_vals["Mark"].config(text=mtxt + ("  ·  Mobile" if mob else ""), foreground=mcol)
        self.btn_mobile.config(text="Mobile ✓ — undo  (M)" if mob else "Keep for mobile  (M)")
        self.btn_keep.config(text="✔ Kept — undo  (K)" if st == "keep" else "✔ Keep  (K)")
        self.btn_ignore.config(text="✖ Ignored — undo  (I)" if st == "ignore" else "✖ Ignore  (I)")
        playing_here = it.id == self.play_id and self._alive()
        self.btn_stop.state(["!disabled"] if self.play_id and self._alive() else ["disabled"])
        self.btn_test.state(["disabled"] if self.testing else ["!disabled"])
        self.btn_play.config(text="↻ Restart preview" if playing_here else "▶ Preview on monitor")

    def _debounce_render(self) -> None:
        if self._resize_job:
            self.root.after_cancel(self._resize_job)
        self._resize_job = self.root.after(80, self._render_big)

    def _render_big(self) -> None:
        w, h = self.img_frame.winfo_width() - 8, self.img_frame.winfo_height() - 8
        if self.cur_pil is not None and (w < 20 or h < 20):
            return
        if self.cur_pil is None or w < 20 or h < 20:
            if self.cur is not None:
                self.img_label.config(image="", text="No preview image")
            self.big_photo = None
            return
        iw, ih = self.cur_pil.size
        scale = min(w / iw, h / ih, 2.0)
        im = self.cur_pil.resize((max(1, int(iw * scale)), max(1, int(ih * scale))), Image.LANCZOS)
        self.big_photo = ImageTk.PhotoImage(im)
        self.img_label.config(image=self.big_photo, text="")

    def _set_text(self, widget: tk.Text, text: str) -> None:
        widget.config(state="normal")
        widget.delete("1.0", "end")
        widget.insert("end", text)
        widget.config(state="disabled")

    def _refresh_log(self) -> None:
        if self.cur and self.cur.id == self.play_id and self.play_log:
            self._set_text(self.log_txt, "\n".join(self.play_log))
            self.log_txt.see("end")
        else:
            self._set_text(self.log_txt, "(start a preview to see linux-wallpaperengine output here)")

    def set_status(self, msg: str) -> None:
        self.status_var.set(msg)

    # ---------------------------------------------------------------- preview / test
    def _alive(self) -> bool:
        return self.play_proc is not None and self.play_proc.poll() is None

    def toggle_preview(self) -> None:
        if self.cur and self.cur.id == self.play_id and self._alive():
            self.stop_preview()
        else:
            self.start_preview()

    def start_preview(self) -> None:
        item = self.cur
        if not item:
            return
        self.stop_preview()
        env = dict(os.environ)
        eff, _x, over = effective(self.cfg, item.id)
        if eff.silent:
            env["SDL_AUDIODRIVER"] = "dummy"
        try:
            p = subprocess.Popen(wpe_cmd(self.cfg, item.folder, self.cfg.silent), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env, text=True,
                                 errors="replace", start_new_session=True)
        except FileNotFoundError:
            messagebox.showerror("Not found", "linux-wallpaperengine was not found in PATH.")
            return
        self.play_proc, self.play_id = p, item.id
        self.frozen = False
        self.play_log.clear()
        if not eff.animation:
            self.root.after(int(self.cfg.freeze_delay * 1000), lambda: self._freeze(p))

        def reader():
            for line in p.stdout:                        # type: ignore[union-attr]
                self.events.put(("log", item.id, line.rstrip()))
        threading.Thread(target=reader, daemon=True).start()
        self.set_status(f"Previewing {item.id} on {self.cfg.monitor}")
        self._refresh_row(item.id)
        self._update_status_line()
        self._refresh_log()

    def _freeze(self, p: subprocess.Popen) -> None:
        """Animation off: let the first frame render, then stop the process so nothing moves."""
        if p is not self.play_proc or p.poll() is not None:
            return
        if effective(self.cfg, self.play_id or "")[0].animation:
            return
        try:
            os.killpg(p.pid, signal.SIGSTOP)
            self.frozen = True
            self.set_status("Animation off — wallpaper frozen on its first frame (turn Animation on to resume)")
        except OSError:
            try:
                p.send_signal(signal.SIGSTOP)
                self.frozen = True
            except OSError:
                pass
        self._update_status_line()

    def stop_preview(self) -> None:
        self.frozen = False
        old = self.play_id
        kill_proc(self.play_proc)
        self.play_proc = self.play_id = None
        if old:
            self._refresh_row(old)
            self.set_status("Preview stopped")
        if self.cur:
            self._update_status_line()
            self._refresh_log()

    def kill_all(self) -> None:
        """Same cleanup as the old script: pkill linux-wallpaperengine (and wpe*.sh)."""
        self.stop_preview()
        kill_proc(self.scan_proc)
        kill_wpe(self.cfg.kill_scripts, daemons=True)       # explicit "kill everything"
        self.set_status("Killed all linux-wallpaperengine" + (" and wpe*.sh (incl. watchers; switch workspace to restart the cycle timer)" if self.cfg.kill_scripts else "") + " processes")

    def test_item(self) -> None:
        item = self.cur
        if not item or self.testing:
            return
        self.stop_preview()
        self.testing = True
        self.set_status(f"Testing {item.id} for {self.cfg.seconds}s…")
        self._update_status_line()

        def work():
            try:
                self.events.put(("test", item.id, check_item(self.cfg, item.folder), None))
            except Exception as e:
                self.events.put(("test", item.id, None, str(e)))
        threading.Thread(target=work, daemon=True).start()

    def _flag(self, item: Item, line: str) -> None:
        if self.results.add(item, line):
            self._refresh_row(item.id)
            self._update_counts()
            if self.cur and self.cur.id == item.id:
                self._update_status_line()

    # ---------------------------------------------------------------- scan
    def start_scan(self) -> None:
        if not self.items:
            return
        skip = self.cfg.skip_ignored
        todo = [i for i in self.items if not (skip and self.review.get(i.id) == "ignore")]
        n_skip = len(self.items) - len(todo)
        if not todo:
            messagebox.showinfo("Scan", "Every item is marked ignored — nothing to scan.")
            return
        eta = len(todo) * self.cfg.seconds / 60
        extra = f"\n{n_skip} ignored item(s) will be skipped." if n_skip else ""
        if not messagebox.askyesno("Scan everything",
                                   f"Test {len(todo)} items (~{eta:.0f} min, {self.cfg.seconds}s each)?{extra}\n\n"
                                   f"This overwrites {self.cfg.out}"):
            return
        self.stop_preview()
        kill_wpe(self.cfg.kill_scripts)
        self.results.reset()
        self.apply_filter()
        self.scan_dialog = ScanDialog(self, len(todo))
        cfg, cancel = self.cfg, self.scan_dialog.cancel

        def set_proc(p):
            self.scan_proc = p

        def work():
            for n, it in enumerate(todo, 1):
                if cancel.is_set():
                    break
                self.events.put(("scan_begin", n, it.id))
                try:
                    line = check_item(cfg, it.folder, set_proc)
                except Exception as e:
                    self.events.put(("scan_result", it.id, None, str(e)))
                    break
                if cancel.is_set():
                    break
                self.events.put(("scan_result", it.id, line, None))
            self.events.put(("scan_done", cancel.is_set()))
        threading.Thread(target=work, daemon=True).start()

    # ---------------------------------------------------------------- misc actions
    def open_folder(self) -> None:
        if self.cur:
            subprocess.Popen(["xdg-open", str(self.cur.folder)], stderr=subprocess.DEVNULL)

    def open_steam(self) -> None:
        if self.cur:
            webbrowser.open(f"https://steamcommunity.com/sharedfiles/filedetails/?id={self.cur.id}")

    def _copy(self, text: str, what: str) -> None:
        self.root.clipboard_clear()
        self.root.clipboard_append(text)
        self.root.update_idletasks()
        self.set_status(f"Copied {what}: {text}")

    def copy_name(self) -> None:
        if self.cur:
            self._copy(self.cur.title, "name")

    def copy_id(self) -> None:
        if self.cur:
            self._copy(self.cur.id, "ID")

    def open_results(self) -> None:
        subprocess.Popen(["xdg-open", self.cfg.out], stderr=subprocess.DEVNULL)

    def quit(self) -> None:
        if self.quitting:
            return
        self.quitting = True
        self.thumb_stop.set()
        if self.scan_dialog:
            self.scan_dialog.cancel.set()
        kill_proc(self.play_proc)
        kill_proc(self.scan_proc)
        kill_wpe(self.cfg.kill_scripts)
        set_gui_busy(False)
        try:
            self.root.destroy()
        except tk.TclError:
            pass

    # ---------------------------------------------------------------- event pump
    def _pump(self) -> None:
        if self.quitting:
            return
        try:
            for _ in range(80):
                self._handle(self.events.get_nowait())
        except queue.Empty:
            pass
        except tk.TclError:
            return
        if self.play_id and self.play_proc is not None and self.play_proc.poll() is not None:
            gone = self.play_id
            self.play_proc = None                        # keep play_id so status shows "exited"
            self._refresh_row(gone)
            self._update_status_line()
        busy = (self._alive() or self.testing or self.scan_dialog is not None
                or (self.scan_proc is not None and self.scan_proc.poll() is None))
        if busy != self._busy:
            self._busy = busy
            set_gui_busy(busy)
        self.root.after(40, self._pump)

    def _handle(self, ev: tuple) -> None:
        kind = ev[0]
        if kind == "items":
            self._on_items(ev[1])
        elif kind == "thumb":
            _, iid, img = ev
            ph = ImageTk.PhotoImage(img)
            self.thumbs[iid] = ph
            if self.tree.exists(iid):
                self.tree.item(iid, image=ph)
        elif kind == "log":
            _, iid, line = ev
            if iid != self.play_id:
                return
            self.play_log.append(line)
            if "Unsupported" in line and iid in self.by_id:
                self._flag(self.by_id[iid], line.strip())
                self.set_status(f"⚠ Unsupported detected in {iid} — saved to results")
            if self.cur and self.cur.id == iid:
                self._refresh_log()
        elif kind == "test":
            _, iid, line, err = ev
            self.testing = False
            if err:
                self.set_status(f"Test failed: {err}")
            elif line:
                self._flag(self.by_id[iid], line)
                self.set_status(f"⚠ {iid}: {line}")
            else:
                self.set_status(f"✓ {iid}: no 'Unsupported' errors in {self.cfg.seconds}s")
            self._update_status_line()
        elif kind == "scan_begin" and self.scan_dialog:
            self.scan_dialog.begin(ev[1], ev[2])
        elif kind == "scan_result":
            _, iid, line, err = ev
            if line:
                self._flag(self.by_id[iid], line)
            if self.scan_dialog:
                self.scan_dialog.result(iid, line, err)
        elif kind == "scan_done" and self.scan_dialog:
            kill_wpe(self.cfg.kill_scripts)             # same final cleanup as the old script
            self.scan_proc = None
            self.scan_dialog.finish(ev[1])
            self.set_status(f"Scan finished — {len(self.results.flagged)} unsupported item(s)")
            self.apply_filter()
        elif kind == "deleted":
            _, iid, still_there, err = ev
            if not still_there:
                self._drop_items({iid})
            if err:
                self.set_status(f"Could not delete {iid}: {err}")
        elif kind == "delete_done":
            self.deleting = False
            if self.cur:
                self.btn_delete.state(["!disabled"])
            self.set_status("Delete finished")


class ScanDialog(tk.Toplevel):
    def __init__(self, app: App, total: int):
        super().__init__(app.root)
        self.app, self.total, self.done = app, total, False
        self.cancel = threading.Event()
        self.title("Scanning for unsupported items")
        self.configure(bg=BG)
        self.geometry("560x420")
        self.transient(app.root)
        self.grab_set()
        self.protocol("WM_DELETE_WINDOW", self.on_button)
        self.n_lbl = ttk.Label(self, text=f"0 / {total}", style="Title.TLabel")
        self.n_lbl.pack(anchor="w", padx=14, pady=(14, 4))
        self.bar = ttk.Progressbar(self, maximum=total)
        self.bar.pack(fill="x", padx=14)
        self.cur_lbl = ttk.Label(self, text="", style="Dim.TLabel")
        self.cur_lbl.pack(anchor="w", padx=14, pady=6)
        ttk.Label(self, text="Flagged so far").pack(anchor="w", padx=14)
        self.lb = tk.Listbox(self, bg=PANEL, fg=RED, bd=0, highlightthickness=0, activestyle="none")
        self.lb.pack(fill="both", expand=True, padx=14, pady=6)
        self.btn = ttk.Button(self, text="Cancel", command=self.on_button)
        self.btn.pack(pady=(0, 12))

    def begin(self, n: int, iid: str) -> None:
        self.bar["value"] = n - 1
        self.n_lbl.config(text=f"{n} / {self.total}")
        self.cur_lbl.config(text=f"Testing {iid} — {self.app.by_id[iid].title}")

    def result(self, iid: str, line: str | None, err: str | None) -> None:
        self.bar["value"] = self.bar["value"] + 1
        if line:
            self.lb.insert("end", f"{iid}  {self.app.by_id[iid].title}")
            self.lb.see("end")
        if err:
            messagebox.showerror("Scan error", err, parent=self)

    def finish(self, cancelled: bool) -> None:
        self.done = True
        self.cur_lbl.config(text="Cancelled" if cancelled else "Done")
        self.btn.config(text="Close", state="normal")

    def on_button(self) -> None:
        if self.done:
            self.app.scan_dialog = None
            self.grab_release()
            self.destroy()
        else:
            self.cancel.set()
            kill_proc(self.app.scan_proc)              # stop the current item right away
            self.btn.config(text="Cancelling…", state="disabled")


class SettingsDialog(tk.Toplevel):
    """The 'Change Setting' menu: playback options + app behaviour."""

    def __init__(self, app: App):
        super().__init__(app.root)
        self.title("Settings")
        self.configure(bg=BG)
        f = ttk.Frame(self, padding=16)
        f.pack(fill="both", expand=True)
        f.columnconfigure(1, weight=1)
        r = 0

        def combo(label, var, values):
            nonlocal r
            ttk.Label(f, text=label).grid(row=r, column=0, sticky="w", pady=4, padx=(0, 16))
            ttk.Combobox(f, textvariable=var, values=values, state="readonly", width=14).grid(
                row=r, column=1, sticky="w")
            r += 1

        def spin(label, var, lo, hi):
            nonlocal r
            ttk.Label(f, text=label).grid(row=r, column=0, sticky="w", pady=4, padx=(0, 16))
            ttk.Spinbox(f, from_=lo, to=hi, width=6, textvariable=var).grid(row=r, column=1, sticky="w")
            r += 1

        def check(label, var):
            nonlocal r
            ttk.Checkbutton(f, text=label, variable=var).grid(row=r, column=0, columnspan=2, sticky="w", pady=3)
            r += 1

        spin("FPS", app.fps_var, 0, 240)
        combo("Scaling", app.scale_var, ["fit", "fill", "stretch", "default"])
        combo("Clamp", app.clamp_var, ["default", "clamp", "border", "repeat"])
        combo("Hwdec", app.hwdec_var, ["auto", "nvdec-copy", "no"])
        spin("Volume (when unmuted)", app.vol_var, 0, 100)
        spin("Seconds / item (test & scan)", app.secs_var, 1, 600)
        check("Particles", app.part_var)
        check("Parallax", app.para_var)
        check("Mouse interaction", app.mouse_var)
        check("Audio muted", app.mute_var)
        check("Audio processing", app.aproc_var)
        ttk.Separator(f).grid(row=r, column=0, columnspan=2, sticky="ew", pady=8)
        r += 1
        check("Auto-preview on select", app.auto_var)
        check("Auto-advance after Keep/Ignore", app.adv_var)
        check("Skip ignored when scanning", app.skip_var)
        check("Also kill wpe*.sh on cleanup", app.killsh_var)
        ttk.Button(f, text="Close", style="Accent.TButton", command=self.destroy).grid(
            row=r, column=0, columnspan=2, sticky="e", pady=(12, 0))
        self.bind("<Escape>", lambda e: self.destroy())
        # place over the main window and force it to the front (some window managers
        # open transient dialogs behind the parent or off-screen)
        self.update_idletasks()
        w, h = self.winfo_reqwidth(), self.winfo_reqheight()
        rx, ry = app.root.winfo_rootx(), app.root.winfo_rooty()
        rw, rh = app.root.winfo_width(), app.root.winfo_height()
        self.geometry(f"{w}x{h}+{max(0, rx + (rw - w) // 2)}+{max(0, ry + (rh - h) // 2)}")
        self.lift()
        self.attributes("-topmost", True)
        self.after(300, lambda: self.attributes("-topmost", False))
        self.focus_force()


class PathsDialog(tk.Toplevel):
    """Folders and results file (playback settings live in Change Setting)."""

    def __init__(self, app: App):
        super().__init__(app.root)
        self.app = app
        self.title("Paths")
        self.configure(bg=BG)
        self.transient(app.root)
        self.grab_set()
        c = app.cfg
        self.vars = {"workshop": tk.StringVar(value=c.workshop), "assets": tk.StringVar(value=c.assets),
                     "out": tk.StringVar(value=c.out)}
        f = ttk.Frame(self, padding=14)
        f.pack(fill="both", expand=True)
        f.columnconfigure(1, weight=1)
        for r, (label, key, kind) in enumerate((("Workshop folder", "workshop", "dir"),
                                                ("Assets folder", "assets", "dir"),
                                                ("Results file", "out", "file"))):
            ttk.Label(f, text=label).grid(row=r, column=0, sticky="w", pady=4, padx=(0, 12))
            ttk.Entry(f, textvariable=self.vars[key], width=56).grid(row=r, column=1, sticky="ew")
            ttk.Button(f, text="…", width=3,
                       command=lambda v=self.vars[key], k=kind: self.browse(v, k)).grid(row=r, column=2, padx=(6, 0))
        b = ttk.Frame(f)
        b.grid(row=3, column=0, columnspan=3, pady=(14, 0), sticky="e")
        ttk.Button(b, text="Cancel", command=self.destroy).pack(side="left", padx=6)
        ttk.Button(b, text="Save", style="Accent.TButton", command=self.save).pack(side="left")

    def browse(self, var: tk.StringVar, kind: str) -> None:
        p = filedialog.askdirectory(parent=self) if kind == "dir" else \
            filedialog.asksaveasfilename(parent=self, initialfile=Path(var.get()).name)
        if p:
            var.set(p)

    def save(self) -> None:
        v, c, a = self.vars, self.app.cfg, self.app
        changed = v["workshop"].get() != c.workshop or v["out"].get() != c.out
        c.workshop, c.assets, c.out = v["workshop"].get(), v["assets"].get(), v["out"].get()
        c.save()
        self.destroy()
        if changed:
            a.reload()
        a.set_status("Paths saved")



# ----------------------------------------------------------------------------- headless scan


def scan_headless(cfg: Config) -> None:
    items = [i for i in load_items(cfg.workshop) if i.id not in set(cfg.ignored)]
    res = Results(cfg.out)
    res.reset()
    try:
        for n, it in enumerate(items, 1):
            print(f"\r[{n}/{len(items)}] {it.id}   ", end="", file=sys.stderr, flush=True)
            line = check_item(cfg, it.folder)
            if line and res.add(it, line):
                print(f"\n{it.id}\t{it.title}\t{line}", file=sys.stderr)
    except KeyboardInterrupt:
        print(f"\nInterrupted. Partial results in {cfg.out}", file=sys.stderr)
        sys.exit(130)
    finally:
        kill_wpe(cfg.kill_scripts)
    print(f"\nDone. {len(res.flagged)} unsupported item(s) listed in {cfg.out}", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description="Wallpaper Engine workshop browser / scanner")
    ap.add_argument("monitor", nargs="?", help="monitor name, e.g. HDMI-A-1")
    ap.add_argument("--scan", action="store_true", help="headless full scan (no GUI)")
    ap.add_argument("--workshop", help="workshop content folder")
    ap.add_argument("--assets", help="wallpaper_engine assets folder")
    args = ap.parse_args()

    cfg = Config.load()
    if args.monitor:
        cfg.monitor = args.monitor
    if args.workshop:
        cfg.workshop = args.workshop
    if args.assets:
        cfg.assets = args.assets

    if args.scan:
        scan_headless(cfg)
        return
    try:
        root = tk.Tk()
    except tk.TclError as e:
        sys.exit(f"Could not open a window ({e}). Use --scan for headless mode.")
    setup_style(root)
    app = App(root, cfg)
    atexit.register(lambda: (kill_wpe(cfg.kill_scripts), set_gui_busy(False)))
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: app.quit())      # like the old script's trap
    root.mainloop()


if __name__ == "__main__":
    main()