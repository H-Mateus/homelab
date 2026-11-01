#!/usr/bin/env python3
"""Generate the two homelab Grafana dashboards as JSON.

    python3 kubernetes/apps/monitoring/dashboards/generate.py

Writes homelab-overview.json and homelab-box.json next to this file;
kustomization.yaml turns them into ConfigMaps that Grafana's sidecar loads.
Edit here, not in the JSON (the dashboards are read-only in the Grafana UI).

Everything is keyed on the `host` label Alloy puts on every series and log
stream (truenas, quack01, frigate, proxmox-k8s, proxmox-ha, pfsense). Links
are relative so no tailnet name ends up in this public repo.
"""
import json
from pathlib import Path

HERE = Path(__file__).parent
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}
UNIX = 'job="integrations/unix"'
BOX_URL = "/d/homelab-box/homelab-box?var-host="

# Memory "used", excluding reclaimable cache. Linux: MemAvailable, plus the
# ZFS ARC on TrueNAS (the kernel doesn't count ARC as available, so TrueNAS
# would otherwise always look ~90% full). FreeBSD (pfSense): free + inactive
# + laundry pages.
MEM_USED = f"""1 - (
  (max by (host) (node_memory_MemAvailable_bytes{{{UNIX}}})
     + (max by (host) (node_zfs_arc_size{{{UNIX}}}) or max by (host) (node_memory_MemAvailable_bytes{{{UNIX}}}) * 0))
  / max by (host) (node_memory_MemTotal_bytes{{{UNIX}}})
  or
  (max by (host) (node_memory_free_bytes{{{UNIX}}} + node_memory_inactive_bytes{{{UNIX}}} + node_memory_laundry_bytes{{{UNIX}}}))
  / max by (host) (node_memory_size_bytes{{{UNIX}}})
)"""
CPU_USED = f'1 - avg by (host) (rate(node_cpu_seconds_total{{{UNIX}, mode="idle"}}[5m]))'
# Non-ZFS roots only: a ZFS root dataset reports ~0% used (per-dataset
# accounting), so TrueNAS / pfSense are left blank and covered by "ZFS pools".
ROOT_USED = (f'1 - max by (host) (node_filesystem_avail_bytes{{{UNIX}, mountpoint="/", fstype!="zfs"}}'
             f' / node_filesystem_size_bytes{{{UNIX}, mountpoint="/", fstype!="zfs"}})')
UPTIME = f"max by (host) (time() - node_boot_time_seconds{{{UNIX}}})"


def zfs(metric_filter=""):
    sel = f'{{{UNIX}, fstype="zfs"{metric_filter}}}'
    rep = lambda e: f'label_replace({e}, "pool", "$1", "device", "([^/]+).*")'
    avail = f"max by (host, pool) ({rep('node_filesystem_avail_bytes' + sel)})"
    used = (f"sum by (host, pool) ({rep('node_filesystem_size_bytes' + sel + ' - node_filesystem_avail_bytes' + sel)})")
    return avail, used


ZFS_AVAIL, ZFS_USED = zfs()
ZFS_FREE_PCT = f"{ZFS_AVAIL} / ({ZFS_USED} + {ZFS_AVAIL})"

# System-level log errors: journal (err/crit/alert/emerg), pfSense syslog
# (error/critical/...), TrueNAS log files (ERROR/CRITICAL). Container output
# has no level label, so it isn't in here.
ERROR_LEVELS = 'level=~"(?i)err|error|crit|critical|alert|emerg"'

_next_id = [0]


def pid():
    _next_id[0] += 1
    return _next_id[0]


def q(expr, ref="A", legend="", instant=False, fmt="time_series", ds=PROM):
    t = {"refId": ref, "datasource": ds, "expr": expr, "legendFormat": legend}
    if instant:
        t.update(instant=True, range=False, format=fmt)
    return t


def pct_thresholds(warn=0.8, crit=0.9):
    return {"mode": "absolute", "steps": [
        {"color": "green", "value": None},
        {"color": "orange", "value": warn},
        {"color": "red", "value": crit}]}


def panel(kind, title, x, y, w, h, targets=None, **kw):
    p = {"id": pid(), "type": kind, "title": title,
         "gridPos": {"x": x, "y": y, "w": w, "h": h}}
    if targets is not None:
        p["targets"] = targets
        p["datasource"] = targets[0]["datasource"]
    p.update(kw)
    return p


def dashboard(uid, title, panels, templating=None, description=""):
    return {
        "uid": uid, "title": title, "description": description,
        "tags": ["homelab"], "timezone": "browser", "editable": False,
        "refresh": "1m", "time": {"from": "now-6h", "to": "now"},
        "schemaVersion": 39, "graphTooltip": 1,
        "templating": {"list": templating or []},
        "links": [
            {"title": "Homelab", "type": "link", "url": "/d/homelab-overview/homelab", "icon": "dashboard"},
            {"title": "Box details", "type": "link", "url": "/d/homelab-box/homelab-box", "icon": "info"},
        ],
        "panels": panels,
    }


# --------------------------------------------------------------------------
# Overview ("Homelab"): Grafana's home page.
# --------------------------------------------------------------------------
y = 0
overview = []

overview.append(panel(
    "alertlist", "Active alerts", 0, y, 24, 7,
    description="Firing and pending alerts from Prometheus and Loki (the same ones that push to the phone).",
    options={
        "viewMode": "list", "groupMode": "default", "groupBy": [],
        "maxItems": 30, "sortOrder": 1, "dashboardAlerts": False,
        "alertName": "", "alertInstanceLabelFilter": '{severity=~"warning|critical"}',
        "datasource": "", "folder": None, "showInstances": True,
        "stateFilter": {"firing": True, "pending": True, "recovering": True,
                        "noData": False, "normal": False, "error": True},
    }))
y += 7

overview.append(panel(
    "stat", "Boxes reporting", 0, y, 24, 4,
    [q(f"max by (host) (up{{{UNIX}}})", legend="{{host}}", instant=True)],
    description="Green = this box's Alloy is sending metrics. Tap a box for its details page.",
    options={"reduceOptions": {"calcs": ["lastNotNull"], "values": False},
             "colorMode": "background", "graphMode": "none", "textMode": "value_and_name",
             "orientation": "auto", "justifyMode": "center"},
    fieldConfig={"defaults": {
        "mappings": [{"type": "value", "options": {
            "1": {"text": "Up", "color": "green"}, "0": {"text": "Down", "color": "red"}}}],
        "color": {"mode": "thresholds"},
        "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]},
        "links": [{"title": "Open ${__field.labels.host}", "url": BOX_URL + "${__field.labels.host}"}],
    }, "overrides": []}))
y += 4

glance_targets = [
    q(CPU_USED, "CPU", instant=True, fmt="table"),
    q(MEM_USED, "MEM", instant=True, fmt="table"),
    q(ROOT_USED, "ROOT", instant=True, fmt="table"),
    q(UPTIME, "UP", instant=True, fmt="table"),
]
overview.append(panel(
    "table", "Boxes at a glance", 0, y, 24, 8, glance_targets,
    description="Memory excludes reclaimable cache (and the ZFS ARC on TrueNAS). Root disk = the OS disk (blank on ZFS boxes: TrueNAS and pfSense are in ZFS pools below).",
    transformations=[
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True},
            "renameByName": {"host": "Box", "Value #CPU": "CPU", "Value #MEM": "Memory",
                             "Value #ROOT": "Root disk", "Value #UP": "Uptime"},
            "indexByName": {"host": 0, "Value #CPU": 1, "Value #MEM": 2, "Value #ROOT": 3, "Value #UP": 4}}},
    ],
    options={"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
    fieldConfig={"defaults": {"unit": "percentunit", "decimals": 0, "thresholds": pct_thresholds(0.8, 0.9),
                              "custom": {"align": "auto", "cellOptions": {"type": "color-text"}}},
                 "overrides": [
                     {"matcher": {"id": "byName", "options": "Box"}, "properties": [
                         {"id": "custom.cellOptions", "value": {"type": "auto"}},
                         {"id": "links", "value": [{"title": "Open ${__value.text}", "url": BOX_URL + "${__value.text}"}]}]},
                     {"matcher": {"id": "byName", "options": "Uptime"}, "properties": [
                         {"id": "unit", "value": "dtdurations"},
                         {"id": "custom.cellOptions", "value": {"type": "auto"}}]},
                 ]}))
y += 8

overview.append(panel(
    "table", "ZFS pools", 0, y, 24, 7,
    [q(ZFS_FREE_PCT, "FREE", instant=True, fmt="table"), q(ZFS_AVAIL, "AVAIL", instant=True, fmt="table")],
    description="Approximate (from per-dataset stats; snapshots and Docker's own datasets aren't counted, so the apps pool reads emptier than it is). Alerts at 20% / 10% free.",
    transformations=[
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {
            "excludeByName": {"Time": True},
            "renameByName": {"host": "Box", "pool": "Pool", "Value #FREE": "Free", "Value #AVAIL": "Free space"},
            "indexByName": {"host": 0, "pool": 1, "Value #FREE": 2, "Value #AVAIL": 3}}},
        {"id": "sortBy", "options": {"sort": [{"field": "Free"}]}},
    ],
    options={"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
    fieldConfig={"defaults": {"custom": {"align": "auto"}}, "overrides": [
        {"matcher": {"id": "byName", "options": "Free"}, "properties": [
            {"id": "unit", "value": "percentunit"}, {"id": "decimals", "value": 0},
            {"id": "thresholds", "value": {"mode": "absolute", "steps": [
                {"color": "red", "value": None}, {"color": "orange", "value": 0.1}, {"color": "green", "value": 0.2}]}},
            {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
        {"matcher": {"id": "byName", "options": "Free space"}, "properties": [{"id": "unit", "value": "bytes"}]},
    ]}))
y += 7

overview.append(panel(
    "logs", "System errors (all boxes)", 0, y, 24, 10,
    [{"refId": "A", "datasource": LOKI, "expr": f'{{host=~".+", {ERROR_LEVELS}}}'}],
    description="Error-level lines from each box's system journal, pfSense syslog and TrueNAS's own logs (not app/container output). Some are harmless noise; alerts cover the ones that matter.",
    options={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
             "enableLogDetails": True, "dedupStrategy": "none", "showLabels": False, "prettifyLogMessage": False}))
y += 10

hosts = ["truenas", "quack01", "frigate", "proxmox-k8s", "proxmox-ha", "pfsense"]
links_md = "\n".join([
    "### Where to look",
    "",
    "- **Something's wrong?** The phone push names the box. Open it below, or tap it in *Boxes reporting*.",
    "- **One box in detail:** " + " · ".join(f"[{h}]({BOX_URL}{h})" for h in hosts),
    "- **Every metric for a box:** [Node Exporter Full](/d/rYdddlPWk/node-exporter-full) "
    "(its *Nodename* picker uses hostnames: `proxmox` = proxmox-k8s, `homeassistant` = proxmox-ha, `Quack01` = quack01)",
    "- **Containers:** [cAdvisor](/d/pMEd7m0Mz/cadvisor-exporter)",
    "- **Search any log:** [Explore](/explore) → Loki → label `host`",
    "- **All alert rules:** [Alert rules](/alerting/list)",
    "",
    "Up/down for each service is in Uptime Kuma; admin UIs are bookmarked on the Home Assistant *Homelab* dashboard.",
])
overview.append(panel("text", "Links", 0, y, 24, 9, options={"mode": "markdown", "content": links_md}))

# --------------------------------------------------------------------------
# Box details ("Homelab – box"): one box, picked by its host label.
# --------------------------------------------------------------------------
_next_id[0] = 0
H = 'host="$host"'
HU = f'{UNIX}, {H}'
box = []
y = 0


def stat(title, expr, x, w, unit="percentunit", thresholds=None, **extra):
    fc = {"unit": unit, "decimals": 0, "color": {"mode": "thresholds"},
          "thresholds": thresholds or pct_thresholds()}
    fc.update(extra.pop("defaults", {}))
    return panel("stat", title, x, y, w, 4, [q(expr, instant=True)],
                 options={"reduceOptions": {"calcs": ["lastNotNull"], "values": False},
                          "colorMode": "background", "graphMode": "none", "textMode": "value",
                          "justifyMode": "center"},
                 fieldConfig={"defaults": fc, "overrides": []}, **extra)


box += [
    stat("Status", f"max(up{{{HU}}})", 0, 4, unit="none",
         thresholds={"mode": "absolute", "steps": [{"color": "red", "value": None}, {"color": "green", "value": 1}]},
         defaults={"mappings": [{"type": "value", "options": {"1": {"text": "Up"}, "0": {"text": "Down"}}}]}),
    stat("CPU", CPU_USED.replace(UNIX, HU), 4, 5),
    stat("Memory", MEM_USED.replace(UNIX, HU), 9, 5),
    stat("Root disk", ROOT_USED.replace(UNIX, HU), 14, 5),
    stat("Uptime", UPTIME.replace(UNIX, HU), 19, 5, unit="dtdurations",
         thresholds={"mode": "absolute", "steps": [{"color": "blue", "value": None}]}),
]
y += 4


def ts(title, targets, x, w, unit, h=8, **kw):
    return panel("timeseries", title, x, y, w, h, targets,
                 fieldConfig={"defaults": {"unit": unit, "min": 0,
                                           "custom": {"fillOpacity": 10, "lineWidth": 1, "showPoints": "never"}},
                              "overrides": []},
                 options={"legend": {"displayMode": "list", "placement": "bottom"},
                          "tooltip": {"mode": "multi"}}, **kw)


box += [
    ts("CPU and memory", [q(CPU_USED.replace(UNIX, HU), "A", "CPU"),
                          q(MEM_USED.replace(UNIX, HU), "B", "Memory")], 0, 12, "percentunit",
       ),
    ts("Network", [
        q(f'sum(rate(node_network_receive_bytes_total{{{HU}, device=~"(en|eth|nic|igb|em|ix|re|bge)[0-9a-z]+"}}[5m]))', "A", "in"),
        q(f'-sum(rate(node_network_transmit_bytes_total{{{HU}, device=~"(en|eth|nic|igb|em|ix|re|bge)[0-9a-z]+"}}[5m]))', "B", "out (shown below 0)"),
    ], 12, 12, "Bps"),
]
box[-1]["fieldConfig"]["defaults"].pop("min")
y += 8

box.append(panel(
    "table", "Containers", 0, y, 24, 8,
    [q(f'sum by (name) (rate(container_cpu_usage_seconds_total{{job="integrations/cadvisor", {H}, name!=""}}[5m]))', "CPU", instant=True, fmt="table"),
     q(f'sum by (name) (container_memory_working_set_bytes{{job="integrations/cadvisor", {H}, name!=""}})', "MEM", instant=True, fmt="table")],
    description="Docker hosts only (TrueNAS, Quack01, Frigate LXC). CPU in cores.",
    transformations=[
        {"id": "merge", "options": {}},
        {"id": "organize", "options": {"excludeByName": {"Time": True},
                                       "renameByName": {"name": "Container", "Value #CPU": "CPU (cores)", "Value #MEM": "Memory"}}},
        {"id": "sortBy", "options": {"sort": [{"field": "Memory", "desc": True}]}},
    ],
    options={"showHeader": True, "cellHeight": "sm", "footer": {"show": False}},
    fieldConfig={"defaults": {"custom": {"align": "auto"}}, "overrides": [
        {"matcher": {"id": "byName", "options": "CPU (cores)"}, "properties": [{"id": "decimals", "value": 2}]},
        {"matcher": {"id": "byName", "options": "Memory"}, "properties": [{"id": "unit", "value": "bytes"}]},
    ]}))
y += 8

box.append(panel(
    "logs", "Errors", 0, y, 24, 9,
    [{"refId": "A", "datasource": LOKI, "expr": f'{{{H}, {ERROR_LEVELS}}}'}],
    description="Error-level system lines for this box (journal, pfSense syslog, TrueNAS logs).",
    options={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True,
             "dedupStrategy": "none", "showLabels": False}))
y += 9

box.append(panel(
    "logs", "All logs (type in Search above to filter)", 0, y, 24, 12,
    [{"refId": "A", "datasource": LOKI, "expr": f'{{{H}}} |~ "(?i)$search"'}],
    description="Everything from this box: system journal, containers (label stack/container), TrueNAS files, pfSense syslog.",
    options={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending", "enableLogDetails": True,
             "dedupStrategy": "none", "showLabels": True}))
y += 12

box.append(panel(
    "stat", "More detail", 0, y, 24, 3,
    [q(f'max by (nodename, instance) (node_uname_info{{{HU}}})', instant=True)],
    description="Opens Node Exporter Full with this box selected.",
    options={"reduceOptions": {"calcs": ["lastNotNull"], "values": False},
             "colorMode": "none", "graphMode": "none", "textMode": "name", "justifyMode": "center"},
    fieldConfig={"defaults": {
        "displayName": "Open every metric for this box (Node Exporter Full) ›",
        "links": [{"title": "Node Exporter Full",
                   "url": "/d/rYdddlPWk/node-exporter-full?var-job=integrations/unix"
                          "&var-nodename=${__field.labels.nodename}&var-node=${__field.labels.instance}"}]},
        "overrides": []}))

box_templating = [
    {"name": "host", "label": "Box", "type": "query", "datasource": PROM,
     "query": {"query": f"label_values(up{{{UNIX}}}, host)", "refId": "host"},
     "definition": f"label_values(up{{{UNIX}}}, host)", "refresh": 2, "sort": 1,
     "current": {"text": "truenas", "value": "truenas"}, "includeAll": False, "multi": False},
    {"name": "search", "label": "Search", "type": "textbox", "query": "", "current": {"text": "", "value": ""}},
]

for name, d in {
    "homelab-overview.json": dashboard(
        "homelab-overview", "Homelab", overview,
        description="Start here: alerts, every box at a glance, links. Generated by dashboards/generate.py."),
    "homelab-box.json": dashboard(
        "homelab-box", "Homelab – box", box, box_templating,
        description="One box in detail. Generated by dashboards/generate.py."),
}.items():
    (HERE / name).write_text(json.dumps(d, indent=1, ensure_ascii=False) + "\n")
    print("wrote", name, "-", len(d["panels"]), "panels")
