"""Creates (and later removes) a throwaway App Store distribution certificate and provisioning profile
through the App Store Connect API, so CI can sign manually without a registered device.

Usage:
  ios_ci_signing.py create <bundle_id> <work_dir>   # writes cert.cer, key.pem, profile.mobileprovision, ids.env
  ios_ci_signing.py cleanup <work_dir>               # revokes the certificate and deletes the profile

Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_FILE (path to the .p8).
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt

API = "https://api.appstoreconnect.apple.com/v1"


def token() -> str:
    with open(os.environ["ASC_KEY_FILE"]) as f:
        key = f.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"], "typ": "JWT"},
    )


def call(method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        API + path,
        method=method,
        data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"::error::App Store Connect {method} {path} failed: {e.code} {e.read().decode()[:600]}")


def create(bundle_id: str, work: str) -> None:
    os.makedirs(work, exist_ok=True)
    key = os.path.join(work, "key.pem")
    csr = os.path.join(work, "cert.csr")
    subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True, capture_output=True)
    subprocess.run(
        ["openssl", "req", "-new", "-key", key, "-out", csr, "-subj", "/CN=UZARO CI/O=CI"],
        check=True,
        capture_output=True,
    )
    with open(csr) as f:
        csr_text = f.read()

    bundles = call("GET", f"/bundleIds?filter[identifier]={bundle_id}&filter[platform]=IOS")["data"]
    bundle = next((b for b in bundles if b["attributes"]["identifier"] == bundle_id), None)
    if bundle is None:
        sys.exit(f"::error::Bundle ID {bundle_id} is not registered in this team")

    cert = call(
        "POST",
        "/certificates",
        {"data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr_text}}},
    )["data"]
    # Recorded before anything else can fail, so cleanup always revokes it.
    with open(os.path.join(work, "ids.env"), "w") as f:
        f.write(f"CERT_ID={cert['id']}\n")
    with open(os.path.join(work, "cert.cer"), "wb") as f:
        f.write(base64.b64decode(cert["attributes"]["certificateContent"]))

    profile = call(
        "POST",
        "/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {
                    # No spaces: ids.env is sourced by bash and appended to GITHUB_ENV.
                    "name": f"UZARO_CI_{os.environ.get('GITHUB_RUN_ID', int(time.time()))}",
                    "profileType": "IOS_APP_STORE",
                },
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                    "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
                },
            }
        },
    )["data"]
    with open(os.path.join(work, "ids.env"), "a") as f:
        f.write(f"PROFILE_ID={profile['id']}\nPROFILE_NAME={profile['attributes']['name']}\nPROFILE_UUID={profile['attributes']['uuid']}\n")
    with open(os.path.join(work, "profile.mobileprovision"), "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))


def cleanup(work: str) -> None:
    path = os.path.join(work, "ids.env")
    if not os.path.exists(path):
        return
    with open(path) as f:
        ids = dict(line.strip().split("=", 1) for line in f if "=" in line)
    if "PROFILE_ID" in ids:
        call("DELETE", f"/profiles/{ids['PROFILE_ID']}")
    if "CERT_ID" in ids:
        call("DELETE", f"/certificates/{ids['CERT_ID']}")


if __name__ == "__main__":
    if sys.argv[1] == "create":
        create(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "cleanup":
        cleanup(sys.argv[2])
    else:
        sys.exit(__doc__)
