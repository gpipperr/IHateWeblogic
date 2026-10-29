# Certificates, keys and trust stores – where what lives, who needs what

The central architecture description of the certificate topic for a Forms &
Reports 14.1.2 installation: the terms, the quality a CA certificate must
have, the three directions of trust, every store of our stack (where, which
format, who may read it, who writes it, who uses it), the customer case with
an own PKI and a TLS-interception firewall, and a concept for managing the
trust anchors centrally. Every script and document of this repository that
touches a certificate store is listed in [section 9](#9-where-the-lib-touches-certificates--link-list)
and links back here.

Markers as in [README.md](README.md): **confirmed (live)** = test host
2026-10-28 (read-only `ls`, `openssl`, `keytool`, `curl`), **documented** =
vendor documentation / pipperr.de ([Sources](#10-sources)), **assumption** =
not verified.

---

## 1. Terms

| Term | Meaning |
|---|---|
| **SSL / TLS** | SSL 2.0 / 3.0 (Netscape, 1995/96) are obsolete and insecure; the successor is **TLS** (1.0 1999 … 1.3 2018). Only TLS 1.2 and 1.3 are acceptable today (our Nginx: `TLSv1.2 TLSv1.3`). "SSL certificate" is colloquial for an X.509 certificate used by TLS. |
| **X.509 certificate** | signed document: subject, issuer, public key, validity, serial, extensions – plus the **signature** of the issuer over all of it |
| **Key pair / CSR** | private key (never leaves its place) + public key; a **CSR** (certificate signing request) carries the public key and the requested subject to a CA |
| **Chain** | **root** CA (self-signed, trust anchor) → **intermediate** / sub-CA (signed by the root, `CA:TRUE`, may be several levels) → **leaf** (server / client / code-signing certificate, `CA:FALSE`). A trust store holds roots (sometimes intermediates), **never leaves**; a server sends leaf + intermediates, **not** the root. |
| **Basic Constraints** | `CA:TRUE` / `CA:FALSE`, `pathlen` = how many CA levels may follow |
| **SAN** | Subject Alternative Name – the host names / IPs a server certificate is valid for; browsers and Java check the SAN, not the CN |
| **Key Usage / EKU** | what the key may do: `keyCertSign` / `cRLSign` (CA), `digitalSignature`; Extended Key Usage `serverAuth`, `clientAuth`, `codeSigning`, `timeStamping` |
| **Identity (key) store vs. trust store** | identity store = **own** private key + certificate chain (server, code signing); trust store = **other parties'** CA certificates I trust (no private keys) |
| **TSA** | Time Stamping Authority – countersigns a code signature with a time, so a signed jar stays valid after the signing certificate expires (`jarsigner -tsa`, our `FORMS_SIGN_TSA_URL`) |
| **CRL / OCSP** | revocation lists / online status; our local CA publishes neither (open point in 08-SSL) |
| **TLS interception** | a firewall / proxy / antivirus terminates TLS, inspects and re-encrypts with a certificate it issues on the fly from its **own** CA – the client must trust that CA |

### 1.1 Formats and containers

| Format | Content | Typical names | Tools | Used here by |
|---|---|---|---|---|
| **PEM** | Base64 text with `-----BEGIN CERTIFICATE-----` (also keys) – one or many certificates | `.pem`, `.crt`, `.cer` | `openssl` | Nginx, OS trust (`update-ca-trust` reads **PEM only**, DER is silently ignored), local CA `ca.crt` |
| **DER** | the same certificate binary | `.cer`, `.der` | `openssl x509 -outform der`, `certutil` | Windows / GPO import (`ca/ca.cer`) |
| **PKCS#7** | certificate bundle without keys | `.p7b`, `.p7c` | `openssl pkcs7`, Windows | chains from Windows CAs |
| **PKCS#8** | a private key, optionally encrypted (`ENCRYPTED PRIVATE KEY`) | `.key`, `.pem` | `openssl pkey` | local CA root key (AES-256) |
| **PKCS#12** | key + certificate chain (+ trusted certs) in one password-protected container – the standard key store format | `.p12`, `.pfx` | `openssl pkcs12`, `keytool` | code-signing keystore `codesign.p12`, **JDK `cacerts`** (default store type `pkcs12` since Java 9), WebLogic `DemoIdentity.p12` / `DemoTrust.p12`, Oracle wallet `ewallet.p12` |
| **JKS / JCEKS** | Java's old proprietary stores | `.jks` | `keytool` | legacy (`wlserver/server/lib/DemoTrust.jks`); convert to PKCS#12 |
| **Oracle wallet** | `ewallet.p12` (PKCS#12, password) + `cwallet.sso` (auto-login copy, no password – protect by file permissions) | wallet directory | `orapki`, `mkstore` | DB client TCPS, DB `UTL_HTTP` (before 26ai `system:`), OPSS bootstrap credentials, ORDS pool credentials |
| **OPSS KSS** | Keystore Service – keystores inside the OPSS store (`keystores.xml`, data in `<prefix>_OPSS`) | – | WLST / EM | not used by our scripts |
| **Windows certificate store** | per machine / user: `Cert:\LocalMachine\Root` (roots), `\CA` (intermediates), `\My` (own identity) | – | `certutil`, `Import-Certificate`, GPO | Forms clients, Reports Builder server |

## 2. Quality of a CA certificate

Three things are often mixed up – they are independent:

| Property | Question | Good | Bad / old |
|---|---|---|---|
| **Signature hash** of the issuer | *with which hash did the issuer sign this certificate?* (`Signature Algorithm`) | `sha256WithRSAEncryption`, `sha384…`, `ecdsa-with-SHA256/384` | **SHA-1, MD5, MD2** |
| **Key algorithm / size** of the certificate | *which key does the certificate carry?* (`Public Key Algorithm`) | RSA ≥ 3072 (roots 4096), ECDSA P-256 / P-384 | RSA 1024, DSA |
| **Protection of the private key / container** | *how is the key file encrypted?* | PKCS#8 / PKCS#12 with AES-256 (PBES2), SHA-256 MAC | DES / 3DES-CBC PEM keys, PKCS#12 with RC2-40 / 3DES + SHA-1 MAC |

**The author's own case:** a customer root CA signed with **SHA-1 / MD5**
caused massive problems – Java and current browsers / OpenSSL refuse such
chains. In Java the rule is in `jdk.certpath.disabledAlgorithms`
(**confirmed (live)**, identical in `JDK_HOME` 21.0.13.0.2 and the bundled JDK
17.0.12):

```
jdk.certpath.disabledAlgorithms=MD2, MD5, SHA1 jdkCA & usage TLSServer, \
    RSA keySize < 1024, DSA keySize < 1024, EC keySize < 224, \
    SHA1 usage SignedJAR & denyAfter 2019-01-01
```

MD5 / MD2 anywhere in the chain fail; SHA-1 fails for TLS server chains that
end in a JDK root, for jars signed after 2019, and – depending on the
version – more cases. Typical messages: `PKIX path validation failed …
Algorithm constraints check failed on signature algorithm: SHA1withRSA`,
OpenSSL `ca md too weak`, browsers `NET::ERR_CERT_WEAK_SIGNATURE_ALGORITHM`.
The self-signature of a root that is imported as a trust anchor is not
checked by every stack – intermediates and leaves never with SHA-1 / MD5,
and a new root should not have it either.

Further requirements for a CA certificate:

- `basicConstraints = critical, CA:TRUE` (+ `pathlen` as needed),
  `keyUsage = critical, keyCertSign, cRLSign`;
- leaves: SAN with every host name, EKU per purpose (`serverAuth` for
  Nginx, `codeSigning` for jars), random serial;
- lifetimes: root 10–20 years, intermediate shorter, TLS leaf ≤ 398 days
  for public CAs (browsers) – private CAs up to 825 days (our default);
- container protection per consumer: OpenSSL 3 writes PKCS#12 with AES-256 /
  PBES2 and a SHA-256 MAC by default – very old Java 8 updates and old
  Windows versions cannot read it; legacy RC2 / 3DES containers need
  `openssl pkcs12 -legacy` with OpenSSL 3 (**documented**). ECDSA keys: check
  every consumer of the chain (old JREs, Oracle wallets) before choosing EC.

**Checklist for the customer's PKI team** (before their root / intermediates
are imported anywhere):

```bash
openssl x509 -in root.pem -noout -text | grep -E 'Signature Algorithm|Public-Key|CA:|Key Usage|Not After'
openssl x509 -in intermediate.pem -noout -text | grep -E 'Signature Algorithm|Public-Key|CA:|pathlen'
openssl verify -CAfile root.pem intermediate.pem                 # chain consistent?
openssl pkcs12 -in identity.p12 -info -noout                     # MAC / encryption of a container
keytool -list -v -keystore identity.p12 -storetype PKCS12        # what Java sees
```

Reference – our local CA (`08-SSL/ssl_local_ca.sh`), **confirmed (live)**:
RSA 4096, `sha256WithRSAEncryption`, `CA:TRUE, pathlen:0`, root key PKCS#8
encrypted (AES-256), `codesign.p12` with SHA-256 MAC (OpenSSL 3 default).

## 3. Three directions of trust

```
  INBOUND  (who proves identity: our server)
    browser / Forms client (JRE, FSAL) --TLS--> Nginx :443 --(127.0.0.1, http)--> WebLogic / ORDS
      client must trust: root of the Nginx certificate (local CA / customer CA / public CA)

  OUTBOUND (who checks: our processes, against their trust store)
    JDK_HOME JVMs, bundled JDK JVMs (WLS, Reports engines, tools)  --TLS--> external services
    OS tools (curl, wget, dnf, getMOSPatch via java), DB UTL_HTTP, Node.js (Claude Code)
      process must trust: root of the remote server - or of the INTERCEPTION CA in between

  CODE     (who checks: the client JRE)
    jacob.jar signed with codesign.p12 (+ TSA)  --download--> Forms client JRE
      client must trust: root of the code-signing chain (+ the TSA chain)
```

TLS terminates at Nginx; WebLogic speaks plain HTTP on 127.0.0.1 with
`WL-Proxy-SSL` (demo SSL ports disabled). The server JDKs therefore need a
trust store only for **outbound** connections (**documented** in
[forms_runtime_architecture.md §1.1](forms_runtime_architecture.md)).
Mutual TLS (client certificates) is not used.

## 4. Inventory of the stack

All values **confirmed (live)** 2026-10-28 on the test host unless marked.

| Store | Path | Format | Owner / mode – who may read | Content | Written by | Read by |
|---|---|---|---|---|---|---|
| **OS trust (master of the OS)** | `/etc/pki/ca-trust/source/anchors/` → `update-ca-trust` → `extracted/pem/tls-ca-bundle.pem` (= `/etc/pki/tls/certs/ca-bundle.crt`), `extracted/java/cacerts` | PEM in, PEM / PKCS#12 out | root, `444` – everyone reads | Mozilla roots from `ca-certificates` (118 in the Java export) + own anchors (**none** today) | `dnf` (errata, e.g. ELSA-2026-88459), root | curl, wget, dnf, openssl, Python, DB 26ai `system:` |
| **Nginx identity** | `/etc/nginx/ssl/fullchain.pem`, `privkey.pem` | PEM | root, dir `700`, key `600` – root only | server leaf + chain, private key | `09-Install/05-root_nginx_ssl.sh` | Nginx |
| **Staging** | `08-SSL/certs/server.crt`, `server.key`, `chain.crt` | PEM | oracle, key `600` (gitignored) | what will be deployed | `08-SSL/ssl_prepare_cert.sh`, `ssl_local_ca.sh` | `05-root_nginx_ssl.sh`, `ssl_config.sh` |
| **Local CA** | `$ORACLE_BASE/admin/pki/ca/` (`ca.key`, `ca.crt`, `ca.cer`, `ca.srl`), `server/`, `codesign/` | PEM / DER / PKCS#8 | oracle, dirs `700`, keys `600` | root key (AES-256, passphrase in `ssl_ca_sec.conf.des3`), root certificate, issued certificates | `08-SSL/ssl_local_ca.sh` | the scripts above; `ca.crt` / `ca.cer` are distributed to clients |
| **Code signing** | `$ORACLE_BASE/admin/pki/codesign/codesign.p12` (`FORMS_SIGN_KEYSTORE`; customer PKI: `…/pki/customer/codesign.p12`) | PKCS#12 | oracle `600` | signing key + chain (password in `forms_sign_sec.conf.des3`) | `ssl_local_ca.sh codesign` or the customer CA | `09-Install/14-oracle_setup_forms.sh` (`jarsigner`) |
| **Server JDK trust** | `$JDK_HOME/lib/security/cacerts` | PKCS#12, `changeit` | `644` | **110** Oracle JDK roots | Oracle (JDK update replaces it) | WLST, getMOSPatch (`java` in `PATH`), our Java tools |
| **Bundled JDK trust** | `$ORACLE_HOME/oracle_common/jdk/lib/security/cacerts` | PKCS#12, `changeit` | oracle `640` | **110** roots of 2024 (17.0.12) | only an Oracle FMW patch (component `oracle.jdk`) | WebLogic servers, Reports server / engines, Forms / Reports tools |
| **JDK blocklists** | `lib/security/blocked.certs`, `java.security` (`disabledAlgorithms`) | text | JDK | distrusted certificates / algorithms | JDK update | every JVM of that JDK |
| **WebLogic keystores** | `$DOMAIN_HOME/security/DemoIdentity.p12`, `DemoTrust.p12`; `wlserver/server/lib/DemoTrust.jks` | PKCS#12 / JKS | oracle `640` / `600` | demo CA (CertGenCA) | domain creation | only the SSL listen ports – **disabled** here; Nginx terminates TLS |
| **OPSS wallets** | `$DOMAIN_HOME/config/fmwconfig/bootstrap/cwallet.sso`, `cwallet.sso` | Oracle wallet (auto-login) | oracle `600` | **credentials**, not certificates (OPSS bootstrap, credential maps) | domain / WLST | all FMW JVMs – see [rcu_middleware_architecture.md](rcu_middleware_architecture.md) |
| **ORDS wallet** | `ords_*/config/databases/default/wallet/cwallet.sso` | Oracle wallet | oracle, config dir `700` | pool credentials | ORDS CLI (`12-APEX-Ords/04-`) | ORDS – TLS of ORDS itself: none, behind Nginx ([ords_architecture.md](ords_architecture.md)) |
| **DB wallet / OS store** | DB home / `sqlnet.ora` / `UTL_HTTP.SET_WALLET` | Oracle wallet or `system:` | DB owner | roots for outbound `UTL_HTTP` (APEX web services) | DBA / `update-ca-trust` | DB 26ai default `system:` (OS store), 19c ≥ 19.16 with `SET_WALLET('system:')` (**documented**, pipperr.de) |
| **Forms client runtime** | jlink runtime in `/srv/formsWeb/jre-<ver>-win-x64-*.zip` → `lib/security/cacerts` | PKCS#12 | served by Nginx | Oracle roots + **`ihw-forms-ca`** (`FORMS_CLIENT_TRUST_CA`) | `09-Install/40-oracle_forms_client_bundle.sh` (`keytool -importcert`) | FSAL (`-cert_truststore java`), code-signing check of `jacob.jar` |
| **Windows clients** | `Cert:\LocalMachine\Root` / `\CA` | Windows store | machine | customer root, our `ca.cer` | GPO / `Import-Certificate` ([doc 40 §5.8](../09-Install/docs/40-forms_client_distribution.md)) | browsers, PowerShell installer, Windows tools |
| **Reports Builder server (Windows)** | `E:\Java\jdk-21\lib\security\cacerts` | PKCS#12 | admin | Oracle roots | JDK update | Builder outbound (none in normal work) – [report_rwbuilder.md](report_rwbuilder.md) |
| **Node.js (Claude Code)** | built into the `node` binary (144 roots) + `NODE_EXTRA_CA_CERTS` | PEM via env | – | Mozilla roots of that Node build | Node update | Claude Code (API, WebFetch) – [setup_claude.md](../10-Monitoring/setup_claude.md) |

Secret files that unlock stores (repository root, gitignored, machine-bound
`des3`): `ssl_ca_sec.conf.des3` (`SSL_CA_PASS`), `forms_sign_sec.conf.des3`
(`FORMS_SIGN_STOREPASS`). Backup: `$ORACLE_BASE/admin/pki` and the `des3`
files are **excluded** from `backup_config.sh` – back up offline
([07-Maintenance/README.md](../07-Maintenance/README.md)).

### 4.1 The two JDK root lists are not the OS root list

Comparison by SHA-256 fingerprint, **confirmed (live)** 2026-10-28:

| | Oracle JDK 21.0.13.0.2 `cacerts` | OS `extracted/java/cacerts` (Mozilla, `ca-certificates` 2026.2) |
|---|---|---|
| entries | 110 | 118 |
| in both | 61 | 61 |
| only here | **49** – e.g. older DigiCert (Global Root CA, Assured ID Root CA), GeoTrust / thawte / VeriSign legacy roots, Entrust EC1 / G2, QuoVadis Root CA 3, Starfield Class 2, **emSign Root CA – G2 (eMudhra)** | **57** |

The bundled JDK 17.0.12 differs from the OS in 55 roots. Consequences: an
outbound connection can work with `curl` and fail in Java or vice versa; a
root removed by an OS erratum (eMudhra, ELSA-2026-88459) stays trusted in
both JDKs until their own update. All outbound targets of this stack verify
against the **OS** store (`curl`, `ssl_verify_result=0`): `updates.oracle.com`,
`support.oracle.com`, `www.oracle.com`, `download.oracle.com` (DigiCert Global
Root G3), `github.com`, `raw.githubusercontent.com`, `api.anthropic.com`.

## 5. Who needs what

| Component | Own identity | Public roots | Customer root + intermediates | Interception CA | Code-signing chain |
|---|---|---|---|---|---|
| Nginx | **yes** (leaf + chain) | – | issuer of its certificate | – | – |
| WebLogic servers, Reports server / engines (bundled JDK) | – (TLS at Nginx) | outbound only (rare) | if they call customer services over TLS | **yes**, if they call out | – |
| WLST, getMOSPatch, own Java tools (`JDK_HOME`) | – | **yes** (MOS, oracle.com) | if internal targets | **yes** | `jarsigner -verify` only |
| OS tools (dnf, curl, wget), Python | – | **yes** | yes | **yes** | – |
| DB (`UTL_HTTP`, APEX web services) | – | yes | yes | **yes** | – |
| Node.js / Claude Code | – | yes (api.anthropic.com, WebFetch) | – | **yes** (`NODE_EXTRA_CA_CERTS`) | – |
| Forms client JRE (FSAL) | – | for the TSA chain | **yes** (Nginx certificate) | if the client is behind one | **yes** (jacob.jar) |
| Browsers / Windows clients | – | yes | **yes** (GPO) | managed by the customer | – |
| Code signing (`jarsigner`) | **yes** (`codesign.p12`) | TSA reachable | – | TSA call goes outbound | – |

## 6. Customer case: own PKI and a TLS-interception firewall

Typical customer: an internal root CA, one or two intermediates, and a
firewall / proxy that **breaks up outbound TLS** and re-signs it with an
interception sub-CA. Problems appear in both directions:

**Inbound** – the Nginx certificate comes from the customer CA:

- Nginx must send leaf **+ all intermediates** (`fullchain.pem`), otherwise
  Java clients fail although browsers work (browsers fetch missing
  intermediates, Java does not – **documented** behaviour, AIA fetching is
  off by default in Java);
- every client must trust the customer root: Windows via GPO, the Forms
  client runtime via `FORMS_CLIENT_TRUST_CA` (import in `40-`), Linux test
  clients via `anchors/`;
- quality check of the customer chain (section 2) **before** it is used –
  SHA-1 / MD5 in the chain breaks Java clients.

In this library: drop the customer files into `08-SSL/user_certs/`
(server, chain, root, code-signing PFX, interception CA – fixed role names)
and run `08-SSL/ssl_customer_certs.sh` – it checks all of the above and
imports with `--apply` ([08-SSL README – Customer certificates](../08-SSL/README.md#customer-certificates)).

**Outbound** – interception re-signs every external TLS connection:

| Who calls out | Symptom without the interception CA | Where the CA has to go |
|---|---|---|
| getMOSPatch / WLST / Java tools (`JDK_HOME`) | `PKIX path building failed: unable to find valid certification path` | `JDK_HOME` `cacerts` |
| WebLogic / Reports JVMs (bundled JDK) | same, in the server / engine log | bundled JDK `cacerts` |
| dnf, curl, wget | `curl: (60) SSL certificate problem: unable to get local issuer certificate` | OS `anchors/` + `update-ca-trust` |
| DB `UTL_HTTP` | `ORA-29024: Certificate validation failure` | OS store (`system:`) or DB wallet |
| Node.js / Claude Code | `UNABLE_TO_GET_ISSUER_CERT_LOCALLY` / `SELF_SIGNED_CERT_IN_CHAIN` | `NODE_EXTRA_CA_CERTS=<pem>` |
| `jarsigner -tsa` | timestamp request fails → unsigned timestamp warning | JDK that runs `jarsigner` |
| Forms clients behind a client-side interception (antivirus) | FSAL TLS error | client runtime / Windows store |

Further pitfalls: certificate pinning or mutual TLS to a vendor endpoint
cannot be intercepted (exception list on the firewall); after a rotation of
the interception CA the old one must be removed everywhere; the interception
sub-CA often needs its root **and** itself as anchors (pipperr.de). An
incident like eMudhra means the opposite – **remove** a root in every store
(OS, every JDK, client runtimes, Node).

How to recognise interception: the issuer of a public site is the company CA
instead of a public one:

```bash
echo | openssl s_client -connect updates.oracle.com:443 -servername updates.oracle.com 2>/dev/null \
  | openssl x509 -noout -issuer      # public: DigiCert ...  intercepted: <company> Interception CA
```

## 7. Centralising the Java trust stores – options

Every JDK has its own `lib/security/cacerts`, and our servers have two JDKs
(+ client runtimes). Options to maintain the anchors in one place:

| Option | How | + | – |
|---|---|---|---|
| **A** `-Djavax.net.ssl.trustStore=…` per JVM | `setUserOverrides.sh` (all WLS JVMs), `REPORTS_JVM_OPTIONS` / `reports.sh`, Node Manager, WLST, getMOSPatch, … | no change inside the JDK | many places – one forgotten JVM keeps the old trust |
| **B** `cacerts` of each JDK = **symlink to the OS-generated store** `/etc/pki/ca-trust/extracted/java/cacerts` | `ln -sf` once per JDK; OS `anchors/` + `update-ca-trust` are the master | **no `-D`**; customer root / interception CA added **once** in the OS; OS removals (`ca-certificates` errata) reach every JDK – the bundled JDK 17.0.12 would have lost the eMudhra roots with ELSA-2026-88459; Oracle Linux / RHEL do the same for their own OpenJDK packages (`/etc/pki/java/cacerts`) | a JDK update or an `oracle.jdk` patch replaces `cacerts` → re-link after every JDK change; the root list changes from Oracle's to Mozilla's (section 4.1 – our outbound targets verify, others to test); Oracle Support may ask about the modified JDK |
| **C** `JDK_JAVA_OPTIONS=-Djavax.net.ssl.trustStore=…` | one environment variable (profile, systemd unit, Node Manager environment) for every `java` launcher ≥ 9 | one place | prints `Picked up JDK_JAVA_OPTIONS` on stderr (breaks output parsing, e.g. `java -version`), not for Java 8, only for processes that inherit the environment |
| **D** **sync script** | central anchor directory → find every `*/lib/security/cacerts` (+ `jre/lib/security` for Java 8), import / delete aliases with prefix `ihw-` via `keytool` | works for any JDK, also those that must keep their own file; can **remove** roots (incident) | own logic; must run again after every JDK update |

**Recommendation (concept):** **B for the server JDKs** – the OS is the
single master for public roots, customer roots and interception CAs – plus a
**check-and-sync script (D)** that finds all JDKs, reports "link in place /
anchors present / old JDK root list", re-links after a JDK update (hook in
`02b-` / `80-`) and imports where a link is not wanted. The Windows client
runtime keeps the import of `40-`; alternative to evaluate: FSAL with
`-Djavax.net.ssl.trustStoreType=Windows-ROOT` (= Windows store, GPO-managed).
Blocklists (`blocked.certs`, `disabledAlgorithms`) stay JDK-specific – a link
changes only the trusted roots.

## 8. Concept: manage, check, store, automate

Status: **concept** – the script is an open item (08-SSL README).

1. **One source directory for trust anchors** (proposal
   `$ORACLE_BASE/admin/pki/trust/`, variable in `environment.conf`): PEM files
   of every CA that has to be trusted besides the public roots – customer
   root(s), intermediates, interception CA, our local CA – with a naming
   rule (`<org>-<role>.pem`) and a README (owner, purpose, expiry). Checked
   with section 2 before a file is added.
2. **Distribution** (as root where needed):
   - OS: copy to `/etc/pki/ca-trust/source/anchors/`, `update-ca-trust`;
   - server JDKs: option B (link) or D (import);
   - Node.js: `NODE_EXTRA_CA_CERTS` in the Claude environment;
   - DB 26ai: nothing (OS store) – older DB: wallet;
   - clients: Windows via GPO (customer), Forms client runtime via `40-`;
   - Nginx: only its own chain (`05-root_nginx_ssl.sh`).
3. **Checks** (read-only, cron-capable like `cert_expiry_check.sh`):
   every anchor present in every store; links intact after JDK updates;
   expiry of anchors, Nginx and code-signing certificates; quality
   (signature hash, key size) of every anchor; interception detection
   (issuer of `updates.oracle.com`); outbound smoke test per stack (curl,
   Java, Node) to the targets of section 4.1.
4. **What never moves:** private keys stay where they are used (Nginx
   `privkey.pem`, `codesign.p12`, CA key) – only certificates are
   distributed; the CA key and the `des3` files are backed up offline.
5. **Incidents:** removing a root = delete from the source directory (or
   rely on the OS erratum) + re-run distribution + check; for the JDK root
   lists until option B is in place: JDK update or `keytool -delete`.

## 9. Where the lib touches certificates – link list

Every script and document that creates, deploys, checks or uses a
certificate store. **Rule:** a new script or document that touches a store
adds itself here and links back to this article.

**Build / change**

| Where | What it does with which store |
|---|---|
| [08-SSL/ssl_local_ca.sh](../08-SSL/README.md) | own root CA, server and code-signing certificates in `$ORACLE_BASE/admin/pki` |
| [08-SSL/ssl_customer_certs.sh](../08-SSL/README.md#customer-certificates) | checks and imports the customer's certificates from the inbox `08-SSL/user_certs/` (server, chain, root, code-signing PFX, interception CA) into `08-SSL/certs/` and `$ORACLE_BASE/admin/pki/customer/` |
| [08-SSL/ssl_prepare_cert.sh](../08-SSL/README.md) | staging certificate: self-signed / local CA / Easy-RSA / CSR for an external CA |
| `08-SSL/ssl.conf.template` | all `SSL_*` variables (paths, key algorithm, lifetimes) |
| [09-Install/04-root_nginx.sh](../09-Install/docs/04-root_nginx.md) | creates `/etc/nginx/ssl` (700) |
| [09-Install/05-root_nginx_ssl.sh](../09-Install/docs/05-root_nginx_ssl.md) | deploys `fullchain.pem` / `privkey.pem`, frontend host |
| `09-Install/nginx-wls.conf.template` | TLS protocols / ciphers, `WL-Proxy-SSL` |
| [09-Install/01-setup-interview.sh](../09-Install/docs/01-setup-interview.md) | signing keystore, TSA, `FORMS_CLIENT_TRUST_CA`, `des3` passwords |
| [09-Install/14-oracle_setup_forms.sh](../09-Install/docs/14-forms-detail-settings.md) | signs `jacob.jar` (`jarsigner`, PKCS#12, TSA) |
| [09-Install/40-oracle_forms_client_bundle.sh](../09-Install/docs/40-forms_client_distribution.md) | imports the client root into the client runtime `cacerts` |
| `09-Install/client_templates/FormsWeb-Setup.ps1` | relies on the Windows store (no import) |
| `09-Install/response_files/domain_config.py.template` | demo SSL ports of the managed servers off |
| [09-Install/02b-root_os_java.sh](../09-Install/docs/01-root_setup_java.md), `07-Maintenance/80-patch_java_os.sh` | `JDK_HOME`, `java.security` (SecureRandom) – a JDK update replaces `cacerts` |
| [12-APEX-Ords/04-install-ords.sh](../12-APEX-Ords/README.md) | ORDS pool wallet; TLS at Nginx |

**Check / monitor**

| Where | What it checks |
|---|---|
| [08-SSL/ssl_config.sh](../08-SSL/README.md) | Nginx certificate / key match, SAN, handshake, TLS versions, expiry |
| [02-Checks/ssl_check.sh](../02-Checks/README.md) | WebLogic keystore type, live TLS on every SSL port, keystore files in the domain |
| [02-Checks/java_check.sh](../02-Checks/README.md) | both JDKs (version, bundled JDK) |
| [02-Checks/clone_check.sh](clone_golden_image.md) | demo SSL ports, host-specific certificate |
| [02-Checks/egress_check.sh](weblogic_outbound_connections.md), `09-Install/04-oracle_pre_checks.sh` | outbound connections, proxy variables |
| [10-Monitoring/cert_expiry_check.sh](../10-Monitoring/README.md) | daily expiry of the served certificate and the local CA (cron, journal `ihw-cert`) |
| [10-Monitoring/cve_inventory.sh](../10-Monitoring/README.md) | OS errata (`ca-certificates`, …), both JDK versions |
| [10-Monitoring/claude_setup_check.sh](../10-Monitoring/setup_claude.md) | secret / key files denied to Claude, Node.js version |

**Background**

| Document | Topic |
|---|---|
| [08-SSL/README.md](../08-SSL/README.md) | certificate lifecycle, local CA, client distribution |
| [09-Install/docs/05-root_nginx_ssl.md](../09-Install/docs/05-root_nginx_ssl.md) | certificate options A–D, Easy-RSA, OS anchors for test clients |
| [09-Install/docs/40-forms_client_distribution.md](../09-Install/docs/40-forms_client_distribution.md) | client runtime trust, Windows store import, Authenticode |
| [forms_jakob_webutil.md](forms_jakob_webutil.md) | code signing: which certificates, who checks, renewal |
| [java_jlink_forms_env.md](java_jlink_forms_env.md) | client runtime `cacerts`, `-cert_truststore java` |
| [forms_runtime_architecture.md](forms_runtime_architecture.md) §1.1 / §1.2 | TLS hops, client-side TLS threat model |
| [rcu_middleware_architecture.md](rcu_middleware_architecture.md) | OPSS keystore service, bootstrap wallet |
| [ords_architecture.md](ords_architecture.md) | ORDS wallet |
| [clone_golden_image.md](clone_golden_image.md) | the certificate as the host-specific part of a clone |
| [weblogic_outbound_connections.md](weblogic_outbound_connections.md) | what the domain sends outside |
| [09-Install/docs/00-patch-references.md](../09-Install/docs/00-patch-references.md) | Java special case, eMudhra incident, Brotli |
| [07-Maintenance/README.md](../07-Maintenance/README.md) | backup scope (pki and `des3` excluded) |

## 10. Sources

- pipperr.de – Database TLS: OS certificate store in 26ai (OS store paths,
  splitting a chain, interception sub-CA, Windows store, Ansible):
  https://pipperr.de/dokuwiki/doku.php?id=dba:database_tls_os_certstore_26ai
- pipperr.de – own CA on Oracle Linux 9 with Easy-RSA (key algorithm,
  lifetimes, SAN, CA backup):
  https://pipperr.de/dokuwiki/doku.php?id=linux:ca_on_oracle_linux_9
- `update-ca-trust(8)` (Oracle Linux 9 / RHEL – `source/anchors`,
  `extracted/` bundles incl. `java/cacerts`)
- Java SE `keytool` and the `java.security` file
  (`jdk.certpath.disabledAlgorithms`, `keystore.type`) – the JDK
  documentation of the installed release
- Oracle WebLogic Server 14.1.2 – Administering Security, "Configuring
  Keystores" (identity / trust keystores, demo keystores)
- Live checks on the test host 2026-10-28: `ls` / `stat` of every store,
  `keytool -list -v` fingerprint comparison, `openssl x509 -text`,
  `curl` / `openssl s_client` to the outbound targets
