# Andock default image distribution

## Request

Replace any manual or debug-time installation of the Andock filesystem image
with a clean, reproducible, end-user path. Publish the validated image as one
native L1 Arweave transaction and configure AndEE using its transaction ID.

## Issue

The current APK embeds an Android sparse image inside `andee-runtime.zip` and
expands it into app-private storage. That makes the APK unnecessarily large and
couples routine application packaging to a rootfs build. Copying a template or
store into an installed app with ADB would bypass the measured provisioning
path and invalidate every resulting security or correctness claim.

An Arweave transaction ID authenticates the transaction, but an HTTPS gateway
response is not independently proven to the app merely because it was fetched
at an ID-shaped URL. The app therefore still needs a locally pinned byte length
and digest before it may use downloaded bytes.

## Options

1. Keep embedding the sparse image in every APK. This is secure when the APK is
   verified, but preserves the slow, heavyweight packaging cycle.
2. Make config contain an arbitrary ID, size, and digest object. This permits
   operator-selected root filesystems, expanding the measured platform contract
   and making a malicious or accidental alternate OS look like stock Andock.
3. Put only `andock-default-image: <transaction-id>` in measured config, while
   retaining the canonical sparse and expanded sizes/digests in the
   source-built manifest packaged with the APK. Download lazily through the
   configured Arweave gateway, verify the sparse bytes, expand them, verify the
   full ext4 digest, then atomically publish the read-only template.

## Decision

Use option 3. It matches the request's ID-only operator contract without
trusting a gateway or allowing configuration to redefine the stock Andock
rootfs. A different rootfs remains a source/release change with reviewable
package locks and provenance. The APK contains only the small canonical
manifest and native execution machinery; it contains no rootfs bytes.

Materialization is lazy on the first Andock member creation so inference and
the HyperBEAM UI can start before the one-time rootfs download finishes. A
partial download or expansion is never a template: an incomplete full-object
download may be retained for a normal HTTP resume attempt, expansion output is
discarded on failure, and only a fully verified ext4 image is atomically
renamed into place. If a gateway answers a resume request with `200`, the
client simply replaces the partial file with that complete response. Member
images continue to be sparse copies of that immutable template.

No ADB, `run-as`, debug shell, mounted guest filesystem, or direct store write
is an allowed provisioning or acceptance path.
