# Growing a retained nonvolatile volume

`lapee-nonvolatile-grow: true` requests ext4 growth during zone admission,
after the encrypted volume is opened and mounted, before LMDB is opened.
It defaults to false. The measured image includes `resize2fs`; the disk key
remains inside the appliance. There is no remote resize or shell endpoint.

Stop the previous writer and verify that its disk is closed. Preserve a cold
encrypted copy, enlarge the backing disk and its existing GPT partition without
changing the partition start, then boot with this option and the intended store
capacity. The LUKS mapping opens over the enlarged partition. Online ext4 growth
uses the mapping's capacity; it does not format or shrink the filesystem.
Growth errors prevent activation of the persistent store.

Verify the same volume identity, both format flags false, filesystem capacity,
retained reads and a fresh write/readback before returning the node to traffic.
Keep LMDB capacity below usable filesystem capacity with operational headroom.
Repeating the option on a fully grown filesystem is a no-op; it does not enlarge
the host's disk or partition. Existing members do not change until a controlled
rejoin. Never mount or decrypt a protected volume on the host to perform growth.
