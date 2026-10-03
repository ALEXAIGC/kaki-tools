#!/usr/bin/env python3
"""Create or reuse a local code-signing identity. Never rotate an existing key."""
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
NAME = "Kaki Tools Native Local"
KEYCHAIN = Path.home() / "Library/Keychains/login.keychain-db"
PUBLIC = ROOT / "macos/Signing"


def command(args, **kwargs):
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        # Import output can contain the stdin command; never expose it.
        raise RuntimeError(f"{Path(args[0]).name} {args[1]} failed ({result.returncode})")
    return result.stdout


def fingerprint(certificate):
    value = command(["/usr/bin/openssl", "x509", "-in", str(certificate),
                     "-noout", "-fingerprint", "-sha1"]).decode().strip()
    return value.split("=", 1)[1].replace(":", "").upper()


def main():
    existing = subprocess.run(["/usr/bin/security", "find-certificate", "-c", NAME,
                               "-p", str(KEYCHAIN)], capture_output=True)
    with tempfile.TemporaryDirectory(prefix="kaki-local-signing-") as directory:
        directory = Path(directory)
        os.chmod(directory, 0o700)
        cert = directory / "certificate.pem"
        if existing.returncode == 0:
            cert.write_bytes(existing.stdout)
        else:
            # Never silently replace the pinned identity when its keychain is missing.
            if (PUBLIC / "local-certificate.sha1").exists():
                raise RuntimeError("Pinned signing identity is missing. Restore its keychain; do not regenerate it.")
            password = secrets.token_urlsafe(36)
            passfile = directory / "passphrase"
            # OpenSSL reads two lines when passin and passout use the same file.
            passfile.write_text(password + "\n" + password + "\n")
            os.chmod(passfile, 0o600)
            config = directory / "openssl.cnf"
            config.write_text("""[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = Kaki Tools Native Local
O = Kaki Tools Local Development
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
""")
            key = directory / "private-key.pem"
            package = directory / "identity.p12"
            previous_mask = os.umask(0o077)
            try:
                command(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072",
                         "-sha256", "-days", "3650", "-config", str(config), "-keyout", str(key),
                         "-out", str(cert), "-passout", "file:" + str(passfile)])
                command(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key),
                         "-in", str(cert), "-name", NAME, "-out", str(package),
                         "-passin", "file:" + str(passfile), "-passout", "file:" + str(passfile),
                         "-certpbe", "PBE-SHA1-3DES", "-keypbe", "PBE-SHA1-3DES"])
                # stdin keeps the one-time import password out of process arguments.
                import_command = ("import " + shlex.quote(str(package)) + " -k " + shlex.quote(str(KEYCHAIN))
                                  + " -P " + shlex.quote(password) + " -T /usr/bin/codesign\n")
                command(["/usr/bin/security", "-i"], input=import_command, text=True)
            finally:
                os.umask(previous_mask)

        sha1 = fingerprint(cert)
        pinned = PUBLIC / "local-certificate.sha1"
        if pinned.exists() and pinned.read_text().strip() != sha1:
            raise RuntimeError("Keychain certificate does not match the pinned identity; refusing to rotate it.")
        identities = command(["/usr/bin/security", "find-identity", "-p", "codesigning"]).decode()
        if sha1 not in identities:
            raise RuntimeError("Certificate exists but its private key is unavailable. Restore the original keychain.")
        # Trust only the code-signing policy, in the current user's trust domain.
        command(["/usr/bin/security", "add-trusted-cert", "-r", "trustRoot", "-p", "codeSign",
                 "-k", str(KEYCHAIN), str(cert)])
        valid = command(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"]).decode()
        if sha1 not in valid:
            raise RuntimeError("Signing identity is not valid; check its Code Signing trust in Keychain Access.")
        PUBLIC.mkdir(exist_ok=True)
        (PUBLIC / "local-certificate.pem").write_bytes(cert.read_bytes())
        pinned.write_text(sha1 + "\n")
        (PUBLIC / "identity.json").write_text(json.dumps({
            "name": NAME, "certificate_sha1": sha1, "type": "local-self-signed",
            "trust_policy": "codeSign only, current user", "private_key": "login keychain; never bundled",
            "notarized": False,
        }, indent=2) + "\n")
        print("Local signing identity is ready: " + NAME)
        print("Public certificate SHA-1: " + sha1)


if __name__ == "__main__":
    main()
