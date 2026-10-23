#!/usr/bin/env python3
"""Fait tourner Foulée (iPhone) et Foulée Watch dans des simulateurs appairés et exécute
les scénarios de scripts/sim/scenarios.json : lancement avec arguments, attentes, captures,
récupération des rapports écrits par l'app (Documents/scenario/*.json|log) et des crashs.

Usage : run_scenarios.py <Foulee.app> <dossier de sortie>
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time

APP = sys.argv[1]
OUT = sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
WATCH_APP = os.path.join(APP, "Watch", "FouleeWatch.app")
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "run.log"), "w")


def log(*a):
    line = " ".join(str(x) for x in a)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


def sh(*cmd, check=True, timeout=300):
    r = subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        log("ÉCHEC", " ".join(cmd), r.stdout[-2000:], r.stderr[-2000:])
        raise RuntimeError(" ".join(cmd))
    return r


def plist_value(app, key):
    return sh("/usr/libexec/PlistBuddy", "-c", f"Print :{key}", os.path.join(app, "Info.plist")).stdout.strip()


def pick_runtime(rt, prefix):
    cands = [r for r in rt["runtimes"] if r["isAvailable"] and r["name"].startswith(prefix)]
    cands.sort(key=lambda r: [int(x) for x in re.findall(r"\d+", r["version"])])
    return cands[-1]


def pick_device_type(runtime, pattern):
    types = [d for d in runtime.get("supportedDeviceTypes", []) if re.search(pattern, d["name"])]
    return types[-1] if types else None


def main():
    rt = json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j").stdout)
    ios = pick_runtime(rt, "iOS")
    wos = pick_runtime(rt, "watchOS")
    phone_type = None
    for name in ("iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro"):
        phone_type = pick_device_type(ios, "^" + re.escape(name) + "$")
        if phone_type:
            break
    phone_type = phone_type or pick_device_type(ios, r"^iPhone")
    watch_type = pick_device_type(wos, r"Apple Watch Series \d+ \(46mm\)") or pick_device_type(wos, r"Apple Watch")
    log("Runtimes :", ios["name"], "/", wos["name"])
    log("Appareils :", phone_type["name"], "/", watch_type["name"])
    phone = sh("xcrun", "simctl", "create", "Foulee iPhone", phone_type["identifier"], ios["identifier"]).stdout.strip()
    watch = sh("xcrun", "simctl", "create", "Foulee Watch", watch_type["identifier"], wos["identifier"]).stdout.strip()
    pair = sh("xcrun", "simctl", "pair", watch, phone, check=False)
    log("Appairage :", pair.returncode, pair.stdout.strip(), pair.stderr.strip())
    for d in (phone, watch):
        sh("xcrun", "simctl", "boot", d)
    sh("xcrun", "simctl", "bootstatus", phone, "-b", timeout=600)
    sh("xcrun", "simctl", "bootstatus", watch, "-b", timeout=600)
    sh("xcrun", "simctl", "status_bar", phone, "override", "--time", "9:41", "--batteryState", "charged",
       "--batteryLevel", "100", "--cellularBars", "4", check=False)
    devices = {"phone": phone, "watch": watch}
    bundles = {"phone": plist_value(APP, "CFBundleIdentifier"), "watch": plist_value(WATCH_APP, "CFBundleIdentifier")}
    log("Bundles :", bundles)
    sh("xcrun", "simctl", "install", phone, APP, timeout=600)
    # Comme sur un vrai appareil : l'app Watch embarquée s'installe via l'iPhone appairé
    # (WatchConnectivity la voit alors installée). Repli : installation directe.
    installed = False
    for _ in range(36):
        apps = sh("xcrun", "simctl", "listapps", watch, check=False).stdout
        if bundles["watch"] in apps:
            installed = True
            break
        time.sleep(5)
    if installed:
        log("Installation Watch : automatique via l'iPhone appairé")
    else:
        w = sh("xcrun", "simctl", "install", watch, WATCH_APP, check=False, timeout=600)
        log("Installation Watch : directe (repli)", w.returncode, w.stderr.strip()[-500:])

    scenarios = json.load(open(os.path.join(HERE, "scenarios.json")))
    results = []
    for sc in scenarios:
        name = sc["name"]
        log("\n=== Scénario", name, "===")
        res = {"name": name, "description": sc.get("description", ""), "screens": [], "ok": True, "notes": []}
        try:
            for step in sc["steps"]:
                kind = step["do"]
                target = step.get("on", "phone")
                udid = devices[target]
                if kind == "appearance":
                    sh("xcrun", "simctl", "ui", udid, "appearance", step["value"], check=False)
                elif kind == "contentsize":
                    sh("xcrun", "simctl", "ui", udid, "content_size", step["value"], check=False)
                elif kind == "launch":
                    args = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"] + step.get("args", [])
                    r = sh("xcrun", "simctl", "launch", "--terminate-running-process", udid, bundles[target], *args, check=False)
                    log("lancement", target, args, r.returncode, r.stdout.strip(), r.stderr.strip()[-300:])
                    if r.returncode != 0:
                        res["ok"] = False
                        res["notes"].append(f"lancement {target} échoué : {r.stderr.strip()[-200:]}")
                elif kind == "terminate":
                    sh("xcrun", "simctl", "terminate", udid, bundles[target], check=False)
                elif kind == "wait":
                    time.sleep(step["seconds"])
                elif kind == "shot":
                    fn = f"{name}__{step['label']}.png"
                    r = sh("xcrun", "simctl", "io", udid, "screenshot", os.path.join(OUT, fn), check=False)
                    res["screens"].append(fn if r.returncode == 0 else f"(capture impossible : {fn})")
                elif kind == "collect":
                    collect(udid, bundles[target], f"{name}__{target}", res)
                    for exp in step.get("expect", []):
                        check(res, f"{name}__{target}", exp)
                elif kind == "push":
                    payload = os.path.join(OUT, f"{name}_push.json")
                    json.dump(step["payload"], open(payload, "w"))
                    sh("xcrun", "simctl", "push", udid, bundles[target], payload, check=False)
        except Exception as e:  # noqa: BLE001
            res["ok"] = False
            res["notes"].append(f"exception : {e}")
        results.append(res)

    # Crashs éventuels
    crashes = []
    for f in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*")):
        if "Foulee" in os.path.basename(f):
            shutil.copy(f, OUT)
            crashes.append(os.path.basename(f))
    json.dump({"results": results, "crashes": crashes, "runtimes": [ios["name"], wos["name"]],
               "devices": [phone_type["name"], watch_type["name"]], "paired": pair.returncode == 0},
              open(os.path.join(OUT, "results.json"), "w"), indent=2, ensure_ascii=False)
    log("Crashs :", crashes or "aucun")
    lines = ["# Résultats simulateurs", "", f"Simulateurs : {phone_type['name']} ({ios['name']}) + {watch_type['name']} ({wos['name']}), appairés : {pair.returncode == 0}", ""]
    for r in results:
        lines.append(f"## {r['name']} — {'OK' if r['ok'] else 'ÉCHEC'}")
        lines.append(r.get("description", ""))
        for c in r.get("checks", []):
            lines.append(f"- {'✅' if c['ok'] else '❌'} {c['label']} → `{c['got']}`")
        for n in r.get("notes", []):
            lines.append(f"- note : {n}")
        lines.append("")
    lines.append(f"Crashs : {', '.join(crashes) if crashes else 'aucun'}")
    open(os.path.join(OUT, "RESULTATS.md"), "w").write("\n".join(lines))


def lookup(data, path):
    cur = data
    for part in path.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        else:
            return None
    return cur


def check(res, prefix, exp):
    """Vérifie une attente sur un rapport JSON de l'app : {file, path, op, value, label}."""
    fn = os.path.join(OUT, f"{prefix}__{exp['file']}")
    label = exp.get("label", f"{exp['path']} {exp['op']} {exp.get('value')}")
    try:
        data = json.load(open(fn))
    except Exception as e:  # noqa: BLE001
        res.setdefault("checks", []).append({"label": label, "ok": False, "got": f"rapport absent ({e})"})
        res["ok"] = False
        return
    v = lookup(data, exp["path"])
    op, want = exp["op"], exp.get("value")
    if op == "eq":
        ok = v == want
    elif op == "ge":
        ok = isinstance(v, (int, float)) and v >= want
    elif op == "gt":
        ok = isinstance(v, (int, float)) and v > want
    elif op == "le":
        ok = isinstance(v, (int, float)) and v <= want
    elif op == "lenge":
        ok = isinstance(v, list) and len(v) >= want
    elif op == "contains":
        ok = isinstance(v, list) and any(want in str(x) for x in v)
    elif op == "notcontains":
        ok = isinstance(v, list) and not any(want in str(x) for x in v)
    elif op == "notnull":
        ok = v is not None
    else:
        ok = False
    shown = v if not isinstance(v, list) else (v if len(v) <= 12 else v[:12] + ["…"])
    res.setdefault("checks", []).append({"label": label, "ok": ok, "got": shown})
    log("  ", "OK " if ok else "ÉCHEC", label, "→", shown)
    if not ok:
        res["ok"] = False


def collect(udid, bundle, prefix, res):
    r = sh("xcrun", "simctl", "get_app_container", udid, bundle, "data", check=False)
    if r.returncode != 0:
        res["notes"].append(f"conteneur introuvable pour {bundle}")
        return
    base = os.path.join(r.stdout.strip(), "Documents", "scenario")
    for f in glob.glob(os.path.join(base, "*")):
        dst = os.path.join(OUT, f"{prefix}__{os.path.basename(f)}")
        shutil.copy(f, dst)
        if f.endswith(".json"):
            try:
                rep = json.load(open(f))
                res.setdefault("reports", []).append(rep)
                if rep.get("failures"):
                    res["ok"] = False
                    res["notes"] += rep["failures"]
            except Exception as e:  # noqa: BLE001
                res["notes"].append(f"rapport illisible {f}: {e}")


if __name__ == "__main__":
    main()
