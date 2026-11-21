#!/usr/bin/env python3
"""Download only the games on a list from a whole-system set torrent.

Add the set torrent to qBittorrent stopped (category romarr), then:

    qbit-select.py <torrent> <list>... [--dry-run] [--prefer USA,World,...]

<torrent> is part of the torrent's name (or its hash), among torrents in
category romarr (--category to change). Each <list> line is a
game title as the set names it, matched loosely: case, punctuation, accents
and a leading/trailing "The" are ignored, so "The Legend of Zelda: The Wind
Waker" matches "Legend of Zelda, The - The Wind Waker (USA)". A line ending
in * matches any title starting with it; /.../ is a regex on the title.
Lines starting with # are comments.

For each listed title the script picks ONE release (all its discs): the
first region in --prefer, skipping demos/betas/protos while a retail
release exists. Every other file is set to "do not download", the chosen
files to normal, and the torrent is started. Lists are cumulative: add a
line and re-run to fetch more (files you drop are deselected but already
downloaded data stays). --dry-run shows the picks and unmatched lines.

qBittorrent: QBIT_URL (default http://127.0.0.1:8080), QBIT_USER and
QBIT_PASS (prompted for if unset). Python 3 standard library only.
"""

import argparse
import getpass
import http.cookiejar
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

NOT_RETAIL = re.compile(
    r"\((?:[^)]*\b)?(Demo|Beta|Proto|Prototype|Kiosk|Sample|Preview|Promo|"
    r"Debug|Trial|Taikenban|Review Copy)\b",
    re.I,
)
DISC = re.compile(r"\s*\((?:Disc|Disk|Side|Track) [^)]*\)", re.I)
REV = re.compile(r"\((?:Rev|v)\s*([\d.]+)\)", re.I)


def norm(title):
    """Loose comparison key: no accents, case, punctuation or 'The'."""
    t = unicodedata.normalize("NFKD", title)
    t = "".join(c for c in t if not unicodedata.combining(c)).lower()
    t = t.replace("&", " and ")
    t = re.sub(r",\s*the\b", " ", t)
    t = re.sub(r"^the\s+", "", t)
    return re.sub(r"[^a-z0-9]", "", t)


class Pattern:
    def __init__(self, line):
        self.line = line
        if len(line) > 2 and line.startswith("/") and line.endswith("/"):
            rx = re.compile(line[1:-1], re.I)
            self.match = lambda title: bool(rx.search(title))
        elif line.endswith("*"):
            key = norm(line[:-1])
            self.match = lambda title: norm(title).startswith(key)
        else:
            key = norm(line)
            self.match = lambda title: norm(title) == key


def read_lists(paths):
    pats = []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for raw in f:
                line = raw.split(" #", 1)[0].strip()
                if line and not line.startswith("#"):
                    pats.append(Pattern(line))
    return pats


def release_of(path):
    """(release path prefix, release name) for a file in the torrent.

    The release is the shallowest path component below the torrent's own
    folder that carries a "(Region)" tag: a per-game folder (cue + bins) or
    the file itself (one .zip/.7z/.chd per game). Files sharing a release
    are selected together.
    """
    parts = path.split("/")
    for i in range(1 if len(parts) > 1 else 0, len(parts)):
        if "(" in parts[i]:
            name = parts[i]
            if i == len(parts) - 1:
                name = re.sub(r"\.[A-Za-z0-9]{1,5}$", "", name)
            return "/".join(parts[: i + 1]), name
    return path, re.sub(r"\.[A-Za-z0-9]{1,5}$", "", parts[-1])


def title_of(name):
    return name.split(" (", 1)[0].strip()


def region_rank(name, prefer):
    m = re.search(r"\(([^)]*)\)", name)
    regions = [r.strip().lower() for r in m.group(1).split(",")] if m else []
    ranks = [prefer.index(r) for r in regions if r in prefer]
    return min(ranks) if ranks else len(prefer)


def rev_key(name):
    """Sorts newest first: Rev 2 < Rev 1 < no revision."""
    m = REV.search(name)
    return tuple(-int(x) for x in m.group(1).split(".") if x) if m else (0,)


def pick(files, patterns, prefer):
    """-> ({file index}, [(line, release name)], [unmatched lines])"""
    releases = {}  # release name without "(Disc N)" -> title + file indexes
    for f in files:
        _, name = release_of(f["name"])
        key = DISC.sub("", name)
        r = releases.setdefault(key, {"title": title_of(key), "idx": set()})
        r["idx"].add(f["index"])

    chosen, picks, unmatched = set(), [], []
    for p in patterns:
        by_title = {}
        for key, r in releases.items():
            if p.match(r["title"]):
                by_title.setdefault(r["title"], []).append(key)
        if not by_title:
            unmatched.append(p.line)
            continue
        for title, keys in sorted(by_title.items()):
            retail = [k for k in keys if not NOT_RETAIL.search(k)] or keys
            best = min(
                retail,
                key=lambda k: (region_rank(k, prefer), rev_key(k), len(k)),
            )
            chosen |= releases[best]["idx"]
            picks.append((p.line, best))
    return chosen, picks, unmatched


class Qbit:
    def __init__(self, url, user, password):
        self.url = url.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        try:
            if user:
                body = self.call("auth/login", username=user, password=password)
                if body.strip() == "Fails.":
                    sys.exit("qBittorrent login failed: wrong user or password.")
            # Newer qBittorrent answers a good login with an empty body, so
            # check the session itself rather than the reply text.
            self.call("app/version")
        except urllib.error.HTTPError as e:
            hint = {
                401: "the session wasn't accepted (wrong user/password?)",
                403: "forbidden: wrong login, or too many failures got this "
                     "IP banned for a while (Options > Web UI)",
            }.get(e.code, e.reason)
            sys.exit(f"qBittorrent login failed: HTTP {e.code}, {hint}.")

    def call(self, path, **data):
        req = urllib.request.Request(
            f"{self.url}/api/v2/{path}",
            data=urllib.parse.urlencode(data).encode(),
            headers={"Referer": self.url},
        )
        with self.opener.open(req, timeout=60) as resp:
            return resp.read().decode()

    def torrent(self, query, category):
        found = [
            t
            for t in json.loads(self.call("torrents/info", category=category))
            if query.lower() in t["name"].lower() or t["hash"] == query.lower()
        ]
        if len(found) != 1:
            names = "\n  ".join(t["name"] for t in found) or "(none)"
            sys.exit(f"'{query}' matches {len(found)} torrents in category "
                     f"'{category}':\n  {names}")
        return found[0]

    def set_priority(self, thash, indexes, prio):
        idx = sorted(indexes)
        for i in range(0, len(idx), 500):  # keep the request size sane
            ids = "|".join(map(str, idx[i : i + 500]))
            self.call("torrents/filePrio", hash=thash, id=ids, priority=prio)

    def start(self, thash):
        try:
            self.call("torrents/start", hashes=thash)  # qBittorrent 5
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            self.call("torrents/resume", hashes=thash)  # 4.x


def size(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PiB"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("torrent", help="part of the torrent's name, or its hash")
    ap.add_argument("lists", nargs="+", help="game list file(s)")
    ap.add_argument("--prefer", default="USA,World,Europe,UK,Japan",
                    help="region order (default: %(default)s)")
    ap.add_argument("--category", default="romarr",
                    help="only look at torrents in this category (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true", help="change nothing")
    ap.add_argument("--no-start", action="store_true", help="don't start it")
    a = ap.parse_args()

    url = os.environ.get("QBIT_URL", "http://127.0.0.1:8080")
    user = os.environ.get("QBIT_USER") or input("qBittorrent user: ")
    password = os.environ.get("QBIT_PASS") or getpass.getpass("Password: ")
    qb = Qbit(url, user, password)

    t = qb.torrent(a.torrent, a.category)
    files = json.loads(qb.call("torrents/files", hash=t["hash"]))
    if not files:
        sys.exit("The torrent has no file list yet (a magnet still fetching "
                 "metadata?). Add it from the .torrent file instead.")
    prefer = [r.strip().lower() for r in a.prefer.split(",")]
    chosen, picks, unmatched = pick(files, read_lists(a.lists), prefer)

    for line, rel in picks:
        print(f"  {rel}" + ("" if norm(title_of(rel)) == norm(line) else f"   <- {line}"))
    total = sum(f["size"] for f in files if f["index"] in chosen)
    print(f"\n{len(picks)} releases, {len(chosen)} files, {size(total)} "
          f"of {size(t['size'] if t['size'] > 0 else sum(f['size'] for f in files))} "
          f"in '{t['name']}'")
    if unmatched:
        print(f"\nNo match for {len(unmatched)} line(s); check the set's naming:")
        for line in unmatched:
            print(f"  {line}")
    if a.dry_run:
        return
    if not chosen:
        sys.exit("Nothing selected; not changing the torrent.")

    qb.set_priority(t["hash"], {f["index"] for f in files} - chosen, 0)
    qb.set_priority(t["hash"], chosen, 1)
    if not a.no_start:
        qb.start(t["hash"])
    print("\nSelection applied" + ("" if a.no_start else " and torrent started") + ".")


if __name__ == "__main__":
    main()
