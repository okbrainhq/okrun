# OkRun Cloud Switch Config UI

## Goal

Let users configure cloud switch access without hand-editing certificate files. The deployment tool can print a bundle, and the OkRun UI can accept it through copy/paste.

## Placement

Extend the existing Private Network panel:

- DHCP Settings
- Bridge Settings
- Cloud Switch Settings
- Status

For MVP, direct Bridge and Cloud Switch are mutually exclusive. If Cloud Switch is enabled, Bridge controls should be disabled or validation should reject applying both.

## Controls

Cloud Switch Settings:

- Enable checkbox.
- Server field: `switch.example.com:9443`.
- Certificate input mode segmented control:
  - Bundle
  - Separate PEM
  - Files

Bundle mode:

- One multiline text area for the JSON bundle from `okrun-switch-ca print-host-bundle`.
- Parse and fill server/PEM values on Apply.

Separate PEM mode:

- CA certificate text area.
- Client certificate text area.
- Client private key text area.

Files mode:

- CA certificate path.
- Client certificate path.
- Client private key path.

## Saved config

Even when the user pastes certs, save files under OkRun home and keep JSON path-based:

```json
{
  "switch": {
    "enabled": true,
    "server": "switch.example.com:9443",
    "caCert": "/Users/me/.okrun/switch/okrun/ca-cert.pem",
    "clientCert": "/Users/me/.okrun/switch/okrun/client-cert.pem",
    "clientKey": "/Users/me/.okrun/switch/okrun/client-key.pem",
    "multipath": false
  }
}
```

Default storage:

```text
~/.okrun/switch/<networkIdentifier>/ca-cert.pem
~/.okrun/switch/<networkIdentifier>/client-cert.pem
~/.okrun/switch/<networkIdentifier>/client-key.pem
```

Permissions:

- Directory `0700`.
- Private key `0600`.
- Certificates `0644` or stricter.

## Validation

On Apply:

- Server must be `host:port`.
- PEM blocks must have expected BEGIN/END labels.
- Private key cannot be empty.
- If bundle mode is used, JSON must contain `server`, `caCertPem`, `clientCertPem`, and `clientKeyPem`.
- Write cert files atomically.
- Reload or reconfigure the runtime switch bridge after saving.

Nice follow-ups:

- Show client certificate expiry.
- Show certificate serial/fingerprint.
- Warn when the cert expires soon.
- Add "Reveal saved folder" later if UI policy allows opening Finder.

## Runtime behavior

After Apply:

1. Save certificate files.
2. Save `private-networks.json`.
3. Build `PrivateNetworkSwitchConfig`.
4. Ask `PrivateNetworkRuntimeRegistry` to configure the switch bridge for the active network.
5. Update status labels.

Status labels:

- Switch Status: Disabled, Connecting, Connected, Rejected, Failed.
- Server: current server address.
- Message: last status or error.

## Security notes

- Do not log pasted private keys.
- Do not keep the private key text in memory longer than needed.
- After a successful save, replace text areas with a neutral saved state or clear them.
- Avoid embedding PEM material into `private-networks.json`.
- Treat pasted bundle parsing errors as validation messages, not fatal app errors.

## E2E/UI tests

Extend GUI smoke tests:

- Open Private Network panel.
- Enable Cloud Switch.
- Paste a generated bundle.
- Apply.
- Assert files are written under temporary `OKRUN_HOME`.
- Assert JSON stores paths, not PEM contents.
- Assert enabling Bridge and Cloud Switch together is rejected.

