# user_certs – inbox for the customer's certificates

Drop the certificates of the customer PKI here, then check and import them:

```bash
./08-SSL/ssl_customer_certs.sh             # check only – nothing is copied
./08-SSL/ssl_customer_certs.sh --apply     # check + import (backups of what is replaced)
./08-SSL/ssl_customer_certs.sh --only server,root --apply
```

Everything in this directory except this README is **gitignored** (keys,
PFX files). Delete the files after the import – the imported copies live
in `08-SSL/certs/` and `$SSL_CA_DIR/customer/`. Background:
[08-SSL/README.md – Customer certificates](../README.md#customer-certificates),
[certificates_trust_stores.md](../../80-FMW-Architecture/certificates_trust_stores.md).

## File names (fixed, by role)

| File | Role | Imported to |
|---|---|---|
| `server.crt` (or `server.cert`, `.cer`, `.pem`) + `server.key` – or `server.p12` / `server.pfx` | TLS certificate of the web server (Nginx) | `08-SSL/certs/server.crt`, `server.key` (600, unencrypted – Nginx cannot ask for a passphrase), then `09-Install/05-root_nginx_ssl.sh --apply` (root) |
| `chain.crt` | intermediate CA(s) of the server certificate (any order) | `08-SSL/certs/chain.crt`, sorted server → root |
| `root.crt` | company root CA | `$SSL_CA_DIR/customer/root.crt`, `FORMS_CLIENT_TRUST_CA` (Forms client bundle), OS trust anchors |
| `codesign.p12` (or `.pfx`) | code-signing certificate + key (`jacob.jar`, client setup script) | `$SSL_CA_DIR/customer/codesign.p12`, `FORMS_SIGN_KEYSTORE` / `FORMS_SIGN_ALIAS`, password → `forms_sign_sec.conf.des3` |
| `interception.crt` | CA of a TLS-interception proxy / firewall (if outbound HTTPS is inspected) | `$SSL_CA_DIR/customer/interception.crt`, OS trust anchors; the `keytool` command for the Java `cacerts` is printed |

Extensions `.crt`, `.cert`, `.cer`, `.pem`, `.der`, `.p7b` are accepted for the
certificates; PEM, DER and PKCS#7 are detected by content and converted to
PEM. Passwords of `server.key`, `server.p12` and `codesign.p12` are asked
by the script (hidden) – never put them into a file here.

## What to request from the customer's PKI team

**Server certificate**
- Subject Alternative Name (SAN) = the **external host name** the users type
  (`WLS_SERVER_FQDN`, e.g. `forms.company.com`), plus further names if used.
  The CN alone is not enough – browsers and Java check the SAN.
- Extended Key Usage `serverAuth`; RSA ≥ 2048 bit (4096 recommended) or EC
  P-256 / P-384; signature SHA-256 or better (no SHA-1 / MD5).
- The **complete chain**: every intermediate CA, plus the root separately.
- Validity ≤ 398 days for public CAs (internal CAs may be longer).
- Either a CSR created by us (`./08-SSL/ssl_prepare_cert.sh REQUEST`, the key
  never leaves the server) **or** a PFX with key + chain and its password on
  a separate channel.

**Code-signing certificate** (only with WebUtil / JACOB or the Forms client
distribution)
- Extended Key Usage `codeSigning`, as PFX with key + chain, password
  separately.
- Issued by a CA the **clients** trust (company root in the Windows store via
  GPO, or a public code-signing CA).

**Root and intermediates** – as files (not only as a screenshot of the
fingerprint), plus the SHA-256 fingerprint to confirm the file.

**Interception CA** – only if the firewall inspects outbound HTTPS (MOS
downloads, `getMOSPatch`, …): the CA certificate the proxy signs with.

## What the script checks

key ↔ certificate, SAN contains the server name, EKU (serverAuth /
codeSigning), validity (expired = FAIL, < 30 days = WARN), signature
algorithm, key size, chain up to `root.crt` (without `root.crt`: against the
OS trust store), `CA:TRUE` of root / interception CA, SHA-256 fingerprints
for the confirmation with the customer. A role with a FAIL is not imported.
