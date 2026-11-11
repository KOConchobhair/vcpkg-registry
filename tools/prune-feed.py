#!/usr/bin/env python3
"""Prune the GitHub Packages NuGet binary cache down to what trunk uses.

The feed only grows: every baseline bump, port revision, triplet edit or runner
image change publishes a fresh set of packages under new ABI hashes, and nothing
ever reads the old ones again. This deletes them.

"Old" is defined by evidence, not by age. The keep set is every 64-hex string in
the logs of one CI run - the latest fully green push run of ports.yml on trunk,
unless --run-id names another. That covers each package the run built, restored
or uploaded, on every leg and in every flavour (vcpkg prints the ABI of each).
The match is deliberately loose: a stray hash in the logs can only keep a
version, never delete one.

A version is deleted when all of these hold:
  - its name has the form <version>-vcpkg<64 hex>, as vcpkg's NuGet names do
    (any other name is left alone)
  - that ABI is not in the keep set
  - it was created before the keep run started (so a run in progress, or a
    newer one, cannot lose what it just published)
A package whose every version qualifies is deleted whole: GitHub refuses to
delete a package's last version on its own.

Dry run by default. --apply deletes, and needs a token with delete:packages:
  gh auth refresh -h github.com -s read:packages,delete:packages

Usage: tools/prune-feed.py [--owner O] [--repo O/R] [--run-id N] [--apply]
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.parse

ABI_IN_NAME = re.compile(r"-vcpkg([0-9a-f]{64})$")
HEX64 = re.compile(r"(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])")
# A run that kept fewer than this many ABIs did not build the manifest; refuse
# to treat it as the definition of what trunk uses.
MIN_KEEP = 100


def gh(*args, text=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=text)
    if r.returncode != 0:
        sys.exit(f"gh {' '.join(args)} failed:\n{r.stderr.strip()}")
    return r.stdout


def gh_json_pages(path):
    # --paginate --slurp yields one JSON array per page.
    pages = json.loads(gh("api", "--paginate", "--slurp", path))
    return [item for page in pages for item in page]


def pick_run(repo, run_id):
    fields = "databaseId,headSha,headBranch,event,status,conclusion,createdAt,jobs"
    if run_id is None:
        runs = json.loads(gh("run", "list", "-R", repo, "--workflow", "ports.yml",
                             "--branch", "trunk", "--event", "push", "--status",
                             "success", "-L", "1", "--json", "databaseId"))
        if not runs:
            sys.exit("no successful push run of ports.yml on trunk")
        run_id = runs[0]["databaseId"]
    run = json.loads(gh("run", "view", str(run_id), "-R", repo, "--json", fields))
    bad = [j["name"] for j in run["jobs"] if j["conclusion"] != "success"]
    if run["conclusion"] != "success" or bad:
        sys.exit(f"run {run_id} is not fully green ({run['conclusion']}; {bad}); "
                 "its logs would not cover every leg")
    return run


def keep_set(repo, run):
    logs = gh("run", "view", str(run["databaseId"]), "-R", repo, "--log")
    keep = set(HEX64.findall(logs))
    if len(keep) < MIN_KEEP:
        sys.exit(f"only {len(keep)} hashes in run {run['databaseId']}'s logs; refusing")
    return keep


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--owner", default="KOConchobhair")
    ap.add_argument("--repo", default="KOConchobhair/vcpkg-registry")
    ap.add_argument("--run-id", type=int)
    ap.add_argument("--apply", action="store_true", help="delete; default is a dry run")
    a = ap.parse_args()

    run = pick_run(a.repo, a.run_id)
    keep = keep_set(a.repo, run)
    print(f"keep set: {len(keep)} hashes from run {run['databaseId']} "
          f"({run['headSha'][:9]}, started {run['createdAt']})")

    base = f"/users/{a.owner}/packages/nuget"
    packages = gh_json_pages(f"/users/{a.owner}/packages?package_type=nuget&per_page=100")
    plan_versions, plan_packages = [], []
    kept_versions = unknown = 0
    for p in sorted(packages, key=lambda p: p["name"]):
        name = urllib.parse.quote(p["name"], safe="")
        versions = gh_json_pages(f"{base}/{name}/versions?per_page=100")
        doomed = []
        for v in versions:
            m = ABI_IN_NAME.search(v["name"])
            if not m:
                unknown += 1
            elif m.group(1) not in keep and v["created_at"] < run["createdAt"]:
                doomed.append(v)
                continue
            kept_versions += 1
        if not doomed:
            continue
        if len(doomed) == len(versions):
            plan_packages.append((p["name"], len(versions)))
        else:
            plan_versions += [(p["name"], v) for v in doomed]

    n_pkg_versions = sum(n for _, n in plan_packages)
    print(f"keep {kept_versions} versions ({unknown} with unrecognised names, left alone)")
    print(f"delete {len(plan_versions)} versions from packages that stay, and "
          f"{len(plan_packages)} whole packages ({n_pkg_versions} versions)")
    for pkg, v in plan_versions:
        print(f"  version  {pkg} {v['name'][:60]} ({v['created_at'][:10]})")
    for pkg, n in plan_packages:
        print(f"  package  {pkg} ({n} versions)")

    if not a.apply:
        print("dry run; pass --apply to delete")
        return
    for pkg, v in plan_versions:
        gh("api", "-X", "DELETE", f"{base}/{urllib.parse.quote(pkg, safe='')}/versions/{v['id']}")
    for pkg, _ in plan_packages:
        gh("api", "-X", "DELETE", f"{base}/{urllib.parse.quote(pkg, safe='')}")
    print(f"deleted {len(plan_versions)} versions and {len(plan_packages)} packages")


if __name__ == "__main__":
    main()
