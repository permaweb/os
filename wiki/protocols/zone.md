# Zone Protocol

`~zone@1.0` creates named shared identities for nodes whose measurements match
a zone template.

## Public Exports

- `init`: create a named zone from the local node after verifying that the
  local boot measurement matches the supplied template.
- `join`: ask an existing member to admit this node.
- `start`: boot hook that schedules joins for zones explicitly configured in
  `zone-allow`.
- `admit`: verify a candidate peer through `~measurement@1.0/verify-peer`,
  match its boot measurement against the zone template, and return encrypted
  zone material.
- `member`: return a membership proof signed by the installed zone identity.
- `status`: list local zone membership state and nonvolatile-storage status.

## Zone Definition

A zone has:

- `name`: local human-readable zone name.
- `template`: AO-Core message matched against normalized boot measurement.
- `ring-reference`: unique reference derived from name, ring address, and
  template identity.
- ring wallet: generated inside the first admitted member and never supplied
  externally.
- zone root secret: generated inside the zone. Admission, wallet encryption,
  and nonvolatile-storage keys are purpose-separated derivations from it.

## Admission

1. Joiner calls `join` with zone name and an admitting member URL.
2. Admitter calls `~measurement@1.0/verify-peer` on the joiner URL.
3. Admitter matches the verified peer boot measurement against the zone
   template.
4. Admitter returns its membership proof and an authorization signed by the
   zone identity. The authorization binds the joiner node address, peer
   attestation ID, recipient ID, ring-reference, template ID, encrypted secret
   ID, issued-at, and expiry.
5. Joiner verifies the membership proof, authorization, and every referenced
   payload by recomputing IDs locally.
6. Joiner unwraps the zone secret through internal measurement helpers,
   decrypts the ring wallet, installs it as an additional identity, and
   activates nonvolatile storage if configured.

Before `init` or `join` installs local zone material, the device evaluates
`zone-allow`. The default is `1`, so a node can join or initialize exactly one
zone unless its operator config opts into more.

If `zone-allow` is a map from zone ID to peer URL, `start` schedules each
listed join after the HTTP listener has come up. This keeps the normal peer
verification flow intact: the admitting peer can still call back into the
joining node's measurement endpoint. The joining node must have a reachable
`public-url` or `zone-self-url` in its node options.

## Membership Proof

`member` returns a bundle: a live node-signed claim plus a zone-signed
countersignature over node address, ring-reference, admission authorization ID,
boot/fresh measurement IDs, issued-at, expiry, and optional caller nonce. The
zone is selected by `ring-reference`; human names are local labels only.
