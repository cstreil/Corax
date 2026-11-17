#!/usr/bin/env python3
"""Vollständiges, rein lesendes IMAP-Backup eines Comail-Kontos.

Lädt jede Mail als rohe .eml-Datei herunter und legt sie unter
<ziel>/<ordner>/<uid>.eml ab, plus manifest.json mit UIDVALIDITY und
Ordnerzählern (für einen späteren Restore).

Sicherheit: SELECT läuft mit readonly=True und der Body wird mit
BODY.PEEK[] geholt — beides verändert serverseitig nichts (kein \\Seen,
kein EXPUNGE, kein STORE). Es werden ausschließlich Lese-Kommandos
gesendet: LIST, SELECT (readonly), UID SEARCH, UID FETCH.

Aufruf:
    python3 scripts/imap-backup.py <zielverzeichnis> [--service comail]

Das Passwort wird aus dem Login-Keychain gelesen (Service/Account wie von
Comail abgelegt) und nie ausgegeben.
"""

import argparse
import base64
import imaplib
import json
import os
import re
import subprocess
import sys
import time

HOST = "imap.mail.me.com"
PORT = 993
USER = "cstreil@me.com"


def keychain_password(service: str, account: str) -> str:
    out = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        sys.exit(f"Keychain-Eintrag {service}/{account} nicht lesbar: {out.stderr.strip()}")
    return out.stdout.strip()


def decode_utf7(name: str) -> str:
    """RFC 3501 modified UTF-7 -> Unicode (für lesbare Ordnernamen)."""
    out = []
    i = 0
    while i < len(name):
        ch = name[i]
        if ch != "&":
            out.append(ch)
            i += 1
            continue
        end = name.find("-", i)
        if end == -1:
            end = len(name)
        chunk = name[i + 1 : end]
        if chunk == "":
            out.append("&")
        else:
            b = chunk.replace(",", "/")
            b += "=" * (-len(b) % 4)
            try:
                out.append(base64.b64decode(b).decode("utf-16-be"))
            except Exception:
                out.append(name[i:end])
        i = end + 1
    return "".join(out)


LIST_RE = re.compile(r'^\((?P<flags>[^)]*)\)\s+"(?P<delim>[^"]*)"\s+(?P<name>.+)$')


def parse_list_line(line: str):
    if isinstance(line, bytes):
        line = line.decode("utf-8", "replace")
    m = LIST_RE.match(line.strip())
    if not m:
        return None
    name = m.group("name").strip()
    if name.startswith('"') and name.endswith('"'):
        name = name[1:-1]
    return name


def safe_dirname(name: str) -> str:
    name = decode_utf7(name)
    name = name.replace("/", "_").replace("\\", "_").replace(":", "_")
    name = re.sub(r'[\x00-\x1f<>"|?*]', "_", name).strip(" .")
    return name or "unnamed"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--service", default="comail")
    ap.add_argument("--account-id", default="1")
    ap.add_argument("--delay", type=float, default=0.0, help="Pause pro Mail in Sekunden")
    args = ap.parse_args()

    target = os.path.abspath(args.target)
    os.makedirs(target, exist_ok=True)

    password = keychain_password(args.service, f"{args.account_id}:password")

    print(f"Verbinde mit {HOST}:{PORT} als {USER} …", flush=True)
    M = imaplib.IMAP4_SSL(HOST, PORT)
    M.login(USER, password)

    typ, raw_folders = M.list()
    if typ != "OK":
        sys.exit("LIST fehlgeschlagen")

    folders = [f for f in (parse_list_line(x) for x in raw_folders) if f]
    print(f"{len(folders)} Ordner gefunden", flush=True)

    manifest = {"host": HOST, "user": USER, "folders": {}, "started": time.strftime("%Y-%m-%dT%H:%M:%S")}
    total = 0
    errors = []

    for folder in folders:
        # readonly=True: garantiert keine serverseitige Änderung.
        typ, data = M.select(f'"{folder}"', readonly=True)
        if typ != "OK":
            errors.append({"folder": folder, "stage": "select", "error": str(data)})
            print(f"  ! SELECT {folder}: {data}", flush=True)
            continue

        uidvalidity = None
        if data and data[0]:
            m = re.search(rb"UIDVALIDITY (\d+)", data[0])
            if m:
                uidvalidity = int(m.group(1))

        typ, data = M.uid("SEARCH", None, "ALL")
        if typ != "OK":
            errors.append({"folder": folder, "stage": "search", "error": str(data)})
            continue
        uids = data[0].split() if data and data[0] else []

        outdir = os.path.join(target, safe_dirname(folder))
        os.makedirs(outdir, exist_ok=True)

        stored = 0
        for uid in uids:
            uid_s = uid.decode() if isinstance(uid, bytes) else str(uid)
            path = os.path.join(outdir, f"{uid_s}.eml")
            if os.path.exists(path) and os.path.getsize(path) > 0:
                stored += 1
                continue
            try:
                typ, msg = M.uid("FETCH", uid_s, "(BODY.PEEK[])")
                if typ != "OK" or not msg or not isinstance(msg[0], tuple):
                    errors.append({"folder": folder, "uid": uid_s, "stage": "fetch", "error": str(msg)[:200]})
                    continue
                raw = msg[0][1]
                with open(path, "wb") as fh:
                    fh.write(raw)
                stored += 1
                total += 1
            except Exception as exc:  # noqa: BLE001
                errors.append({"folder": folder, "uid": uid_s, "stage": "fetch", "error": str(exc)[:200]})
            if args.delay:
                time.sleep(args.delay)

        manifest["folders"][folder] = {
            "dir": safe_dirname(folder),
            "uidvalidity": uidvalidity,
            "messages": len(uids),
            "stored": stored,
        }
        print(f"  {folder}: {stored}/{len(uids)}", flush=True)

    M.logout()

    manifest["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    manifest["total_downloaded"] = total
    manifest["errors"] = errors
    with open(os.path.join(target, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)

    print(f"\nFertig: {total} Mails neu geladen, {len(errors)} Fehler")
    print(f"Manifest: {os.path.join(target, 'manifest.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
