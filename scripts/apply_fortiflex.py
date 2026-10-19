#!/usr/bin/env python3
"""Generate FortiFlex VM tokens and license the deployed units.

Reads the FortiFlex credentials, the entitlement serial numbers and the admin password from terraform.tfvars
(through `terraform console`, so the values are exactly what Terraform sees) and the management addresses from
`terraform output -json`.

  FortiGates (4)  token generated, then applied through the FortiOS REST API
                  (POST /api/v2/monitor/system/vmlicense/download?token=...). The unit reboots.
  FortiManager / FortiAnalyzer
                  token generated, then applied through JSON-RPC (exec /sys/vm/license, UNVERIFIED path). If the
                  API rejects it, the token is printed so you can run `execute vm-license <token>` by hand.

Default is a dry run: nothing is called. Add --execute to generate tokens and apply them.

  scripts/apply_fortiflex.py                       # dry run, shows the plan
  scripts/apply_fortiflex.py --execute             # license everything
  scripts/apply_fortiflex.py --execute --only fmg faz
  scripts/apply_fortiflex.py stop --execute        # stop the entitlements (do this after terraform destroy)

Standard library only. FortiFlex tokens are one-time: a token is generated immediately before it is used.
"""
import argparse
import http.cookiejar
import json
import os
import ssl
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "terraform")  # terraform runs here
# python.org builds on macOS ship without a CA bundle; fall back to the system one (verification stays on)
if not os.environ.get("SSL_CERT_FILE") and os.path.exists("/etc/ssl/cert.pem"):
    os.environ["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"

AUTH_URL = "https://customerapiauth.fortinet.com/api/v1/oauth/token/"
API = "https://support.fortinet.com/ES/api/fortiflex/v2/entitlements"
UNITS = ["site_a_primary", "site_a_secondary", "site_b_primary", "site_b_secondary", "fmg", "faz"]


def terraform(*args, stdin=None):
    # stale AWS keys in the shell override an SSO login, and Terraform does not need them to read variables
    env = {k: v for k, v in os.environ.items() if k not in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN")}
    return subprocess.run(["terraform", *args], cwd=ROOT, env=env, capture_output=True, text=True, input=stdin)


def load_config():
    expr = ("nonsensitive(jsonencode({user=var.fortiflex_username, password=var.fortiflex_password, "
            "fgt=var.fortigate_sns, fmg=var.fortimanager_sn, faz=var.fortianalyzer_sn, "
            "admin_password=local.fortigate_admin_password, fmg_password=local.fortimanager_admin_password, "
            "faz_password=local.fortianalyzer_admin_password}))")
    p = terraform("console", stdin=expr)
    out = p.stdout.strip()
    if p.returncode != 0 or not out.startswith('"'):
        sys.exit("could not read the variables with `terraform console`:\n" + (p.stderr or out)[:600])
    return json.loads(json.loads(out))


def load_outputs(path):
    if path:
        with open(path) as f:
            return json.load(f)
    p = terraform("output", "-json")
    if p.returncode != 0:
        sys.exit("terraform output failed:\n" + p.stderr[:600])
    return json.loads(p.stdout or "{}")


def targets(cfg, outs):
    """name -> {sn, host, kind}"""
    def val(name, *keys):
        v = (outs.get(name) or {}).get("value")
        for k in keys:
            v = v.get(k) if isinstance(v, dict) else None
        return v
    t = {}
    for site in ("site_a", "site_b"):
        sns = cfg["fgt"].get(site, [])
        for i, role in enumerate(("primary", "secondary")):
            t[f"{site}_{role}"] = {"sn": sns[i] if i < len(sns) else "", "host": val(site, role, "mgmt_eip"), "kind": "fgt"}
    t["fmg"] = {"sn": cfg["fmg"], "host": val("management", "fortimanager_eip"), "kind": "fmgfaz"}
    t["faz"] = {"sn": cfg["faz"], "host": val("management", "fortianalyzer_eip"), "kind": "fmgfaz"}
    return t


def post_json(url, body, headers=None, timeout=30):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or "{}")
        except ValueError:
            return e.code, {}


def oauth_token(cfg):
    status, body = post_json(AUTH_URL, {"username": cfg["user"], "password": cfg["password"],
                                        "client_id": "flexvm", "grant_type": "password"})
    if status != 200 or "access_token" not in body:
        sys.exit(f"FortiFlex login failed (HTTP {status}): {json.dumps(body)[:300]}")
    return body["access_token"]


def flex(call, sn, token):
    return post_json(f"{API}/{call}", {"serialNumber": sn}, {"Authorization": f"Bearer {token}"})


def vm_token(sn, token):
    # a STOPPED entitlement has to be reactivated first (the autoscale Lambda does the same); 400/-1 means PENDING
    status, body = flex("reactivate", sn, token)
    if status not in (200, 400):
        print(f"    reactivate {sn}: HTTP {status} {json.dumps(body)[:200]}")
    status, body = flex("vm/token", sn, token)
    ents = body.get("entitlements") if isinstance(body, dict) else None
    if status != 200 or not ents:
        sys.exit(f"could not generate a token for {sn} (HTTP {status}): {json.dumps(body)[:300]}")
    return ents[0]["token"]


def ssh_run(host, password, command, answer="", timeout=180):
    """Run one CLI command over ssh as admin. The password goes through SSH_ASKPASS from the environment, never
    onto a command line or into a file. Host keys are not checked: the demo addresses change on every deploy."""
    fd, askpass = tempfile.mkstemp(suffix=".sh")
    try:
        os.write(fd, b'#!/bin/sh\nprintf "%s\\n" "$ASKPASS_PW"\n')
        os.close(fd)
        os.chmod(askpass, stat.S_IRWXU)
        env = {**os.environ, "SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force", "ASKPASS_PW": password,
               "DISPLAY": os.environ.get("DISPLAY") or "none"}
        cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
               "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
               "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=20", f"admin@{host}", command]
        # keep stdin open and answer after the prompt appears: EOF at a y/n prompt cancels it
        p = subprocess.Popen(cmd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            if answer:
                time.sleep(8)
                try:
                    p.stdin.write(answer)
                    p.stdin.flush()
                except (BrokenPipeError, OSError):
                    pass
            out, _ = p.communicate(timeout=timeout)
            return p.returncode, (out or "").strip()
        except subprocess.TimeoutExpired:
            p.kill()
            out, _ = p.communicate()
            return 255, ((out or "") + "\nssh timed out").strip()
    finally:
        os.unlink(askpass)


def ssh_serial(host, password):
    rc, out = ssh_run(host, password, "get system status", timeout=60)
    m = re.search(r"Serial[- ]Number\s*:\s*(\S+)", out)
    return m.group(1) if m else ""


def ssh_license(host, password, token):
    """exec vm-license over ssh; the unit reboots, so the connection ending is the expected outcome"""
    rc, out = ssh_run(host, password, f"execute vm-license {token}", answer="y\n", timeout=240)
    return out


class FortiGate:
    def __init__(self, host, user, password):
        self.base = f"https://{host}"
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx),
                                                  urllib.request.HTTPCookieProcessor(self.jar))
        self.csrf = ""
        self.user, self.password = user, password

    def login(self):
        data = urllib.parse.urlencode({"username": self.user, "secretkey": self.password, "ajax": 1}).encode()
        with self.opener.open(urllib.request.Request(self.base + "/logincheck", data=data), timeout=20):
            pass
        for c in self.jar:
            if c.name.startswith("ccsrftoken"):
                self.csrf = c.value.strip('"')
        if not self.csrf:
            raise RuntimeError("login did not return a CSRF token (wrong password, or admin access not allowed from here)")

    def call(self, method, path, timeout=30):
        req = urllib.request.Request(self.base + path, method=method, data=b"" if method == "POST" else None,
                                     headers={"X-CSRFTOKEN": self.csrf})
        with self.opener.open(req, timeout=timeout) as r:
            return json.loads(r.read() or "{}")

    def serial(self):
        self.login()
        return self.call("GET", "/api/v2/monitor/system/status").get("serial", "")


class JsonRpc:
    """FortiManager / FortiAnalyzer JSON-RPC (POST /jsonrpc)."""

    def __init__(self, host, password):
        self.url = f"https://{host}/jsonrpc"
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE
        self.session = None
        self.user, self.password = "admin", password

    def rpc(self, method, url, data=None, timeout=60):
        param = {"url": url}
        if data is not None:
            param["data"] = data
        body = {"id": 1, "method": method, "params": [param]}
        if self.session:
            body["session"] = self.session
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, context=self.ctx, timeout=timeout) as r:
            return json.loads(r.read() or "{}")

    def login(self):
        res = self.rpc("exec", "/sys/login/user", {"user": self.user, "passwd": self.password})
        self.session = res.get("session")
        if not self.session:
            raise RuntimeError("login failed: " + json.dumps(res.get("result", res))[:200])

    def serial(self):
        self.login()
        res = self.rpc("get", "/sys/status")
        data = (res.get("result") or [{}])[0].get("data") or {}
        return data.get("Serial Number", "")

    def license(self, token):
        """returns (ok, message)"""
        self.login()
        res = self.rpc("exec", "/sys/vm/license", {"token": token}, timeout=120)
        st = (res.get("result") or [{}])[0].get("status") or {}
        return st.get("code") == 0, f"{st.get('code')} {st.get('message', '')}".strip()


def wait_licensed(host, password, sn, timeout=900, kind="fgt"):
    end = time.time() + timeout
    while time.time() < end:
        try:
            unit = FortiGate(host, "admin", password) if kind == "fgt" else JsonRpc(host, password)
            if unit.serial() == sn:
                return True
        except Exception:
            pass
        try:
            if ssh_serial(host, password) == sn:
                return True
        except Exception:
            pass
        time.sleep(20)
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", nargs="?", default="apply", choices=["apply", "stop"])
    ap.add_argument("--execute", action="store_true", help="call the FortiFlex API and the units (default is a dry run)")
    ap.add_argument("--only", nargs="+", choices=UNITS, help="limit to these units")
    ap.add_argument("--outputs-json", help="read `terraform output -json` from this file (testing)")
    args = ap.parse_args()

    cfg = load_config()
    outs = load_outputs(args.outputs_json)
    tgt = {k: v for k, v in targets(cfg, outs).items() if not args.only or k in args.only}

    print(f"{args.command}: {'EXECUTE' if args.execute else 'dry run (nothing is called)'}")
    missing = False
    for name, t in tgt.items():
        print(f"  {name:18} sn={t['sn'] or '(not set)':18} host={t['host'] or '(no address)'}")
        if not t["sn"] or (args.command == "apply" and not t["host"]):
            missing = True
    if not args.execute:
        if missing:
            print("some units have no serial number or address yet (not fatal for a dry run)")
        return
    if missing:
        sys.exit("refusing to run: fill in the serial numbers (tfvars) and deploy first so the addresses exist")
    if not cfg["user"] or not cfg["password"]:
        sys.exit("fortiflex_username / fortiflex_password are empty in terraform.tfvars")

    tok = oauth_token(cfg)
    if args.command == "stop":
        for name, t in tgt.items():
            status, body = flex("stop", t["sn"], tok)
            print(f"  stop {name}: HTTP {status}")
        return

    applied = []
    for name, t in tgt.items():
        if t["kind"] == "fgt":
            try:
                if FortiGate(t["host"], "admin", cfg["admin_password"]).serial() == t["sn"]:
                    print(f"  {name}: already licensed ({t['sn']}), skipping")
                    continue
            except Exception as e:
                # an unlicensed VM has no REST login, so fall through to the token and the manual command
                print(f"  {name}: could not read the serial from {t['host']} ({e}); continuing")
            token = vm_token(t["sn"], tok)
            try:
                fgt = FortiGate(t["host"], "admin", cfg["admin_password"])
                fgt.login()
            except Exception as e:
                print(f"  {name}: REST login failed ({e}); applying the token over ssh")
                out = ssh_license(t["host"], cfg["admin_password"], token)
                print(f"    {out[-300:]}" if out else "    (no output; the unit is probably rebooting)")
                print(f"    if that did not work, run on {t['host']}: execute vm-license {token}")
                applied.append((name, t))
                continue
            print(f"  {name}: applying token")
            try:
                res = fgt.call("POST", "/api/v2/monitor/system/vmlicense/download?token=" + urllib.parse.quote(token), timeout=120)
                print(f"    {json.dumps(res)[:200]}")
            except Exception as e:
                # the unit reboots as the license lands, which can cut the connection
                print(f"    connection ended ({e}); the unit is probably rebooting")
            applied.append((name, t))
        else:
            pw = cfg["fmg_password"] if name == "fmg" else cfg["faz_password"]
            try:
                if JsonRpc(t["host"], pw).serial() == t["sn"]:
                    print(f"  {name}: already licensed ({t['sn']}), skipping")
                    continue
            except Exception as e:
                print(f"  {name}: could not read the serial from {t['host']} ({e}); continuing")
            token = vm_token(t["sn"], tok)
            try:
                ok, msg = JsonRpc(t["host"], pw).license(token)
            except Exception as e:
                ok, msg = False, f"connection ended ({e})"
            if ok:
                print(f"  {name}: token accepted, the unit is rebooting")
                applied.append((name, t))
            else:
                print(f"  {name}: API did not apply the token ({msg}); applying it over ssh")
                out = ssh_license(t["host"], pw, token)
                print(f"    {out[-300:]}" if out else "    (no output; the unit is probably rebooting)")
                print(f"    if that did not work, run on {t['host']}: execute vm-license {token}")
                applied.append((name, t))

    for name, t in applied:
        pw = cfg["admin_password"] if t["kind"] == "fgt" else (cfg["fmg_password"] if name == "fmg" else cfg["faz_password"])
        ok = wait_licensed(t["host"], pw, t["sn"], kind=t["kind"])
        print(f"  {name}: {'licensed, serial ' + t['sn'] if ok else 'NOT licensed after 15 minutes, check the unit'}")


if __name__ == "__main__":
    main()
