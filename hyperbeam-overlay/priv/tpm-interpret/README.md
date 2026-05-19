# `~tpm-interpret@1.0` database

Static JSON database consumed by `src/hb_db_tpm.erl` at node startup.
Ships inside the HyperBEAM release; load-once, read-many.

Layout:

| file | content |
|---|---|
| `manufacturers.json` | TCG-assigned TPM vendor IDs → `{name, kind, notes}`. Key is the 4-byte ASCII id expressed as 8 hex chars (`"49465800"` = Infineon). Covers every public TCG vendor registration (about 27 entries). |
| `pcr-profiles/*.json` | Known PCR 0/1/7/4/11 values for specific firmware + Secure Boot configurations. Each file is one profile. |
| `uki-measurements/*.json` | Known UKI-style PCR 11/12/13 values for canonical kernel images. |
| `root-cas/*.pem` | TPM EK root/intermediate CA corpus shipped in the image and used by the verifier to chain EK certificates. Refresh with `scripts/fetch-ek-root-cas.sh` when the trusted manufacturer corpus changes. |

## PCR-profile schema

```json
{
    "name": "short human label",
    "match-pcrs": {
        "0": "<base64url-sha256-of-expected-pcr0>",
        "1": "<base64url-sha256-of-expected-pcr1>",
        "7": "<base64url-sha256-of-expected-pcr7>"
    },
    "attributes": {
        "platform-vendor": "Lenovo",
        "platform-model":  "ThinkPad X1 Carbon Gen 11",
        "firmware-vendor": "Lenovo",
        "firmware-version": "N50HT36W (1.20)",
        "secure-boot-enabled": true,
        "secure-boot-authorities": ["Microsoft UEFI CA", "Lenovo"],
        "measured-on": "2024-08-15",
        "contributed-by": "optional-verifier-identity"
    },
    "notes": "Free-form — caveats, known CVEs, etc."
}
```

PCR digests in `match_pcrs` are always **base64url-encoded SHA-256
digests (43 characters, no padding)** — the same encoding the
`~tpm-interpret@1.0/pcrs` output produces for each PCR's `digest`
field, and the same convention used by every other binary value on
the HyperBEAM wire. *Never* hex.

`match_pcrs` need not cover every PCR; a profile matches when *all*
keys it lists match the quoted values. So one profile can pin just
PCR 0 + PCR 7 and leave PCR 1 free for kernel-command-line variance.

## Contributing new profiles

1. Boot the target hardware into a trusted state.
2. Capture a node measurement with `~measurement@1.0/boot`, then run the
   TPM evidence through `~tpm-interpret@1.0`. Copy the `digest` values
   straight out of the `pcrs` section of the response. They are already
   base64url.
   (If you are measuring outside HB: the raw 32-byte SHA-256 digest
   passed through `hb_util:encode/1` or Python's
   `base64.urlsafe_b64encode(d).rstrip(b"=")`.)
3. Fill in the JSON and drop it in `pcr-profiles/`.
4. The matcher picks the first entry that matches all listed PCRs,
   so order of file inclusion doesn't matter for correctness — but
   include enough PCRs that your profile is distinctive.

## Current coverage

This corpus is deliberately data-driven. When new hardware is onboarded,
add PCR profiles, UKI measurements, firmware-family entries, or EK CAs
here and rebuild the image; the verifier loads the data at startup.
