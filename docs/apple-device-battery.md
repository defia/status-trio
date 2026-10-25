# Apple device battery rows

Enable **Show Apple devices and battery** in **Settings → Bluetooth**. The
Bluetooth list can show trusted Apple devices from the companion helper and
named nearby Apple BLE discoveries. A nearby name or advertisement is not proof
of ownership. BLE devices retain separate UUID identities; they are never
merged with paired devices by name.

The Bluetooth battery setting controls reads. A nearby BLE battery read runs
only while its row is actually visible in the status popover. The Apple-device
setting, Bluetooth list setting, unhidden row, and viewport visibility must all
allow the row. Closing the popover, hiding/folding/scolling the row out of view,
turning either setting off, or losing Bluetooth availability revokes the read
permit and cancels active work. Opening Settings may perform bounded discovery
to populate named rows, but never reads a battery there.

### Reading a phone over the air (#152)

An iPhone or an iPad allows a Battery Service read only after it asks to pair,
and that prompt belongs to the phone. The app cannot answer it, remember the
answer, or ask macOS to ignore it. Reading a phone over Bluetooth is therefore
its own setting, **Read iPhone and iPad battery over Bluetooth**, off by
default and separate from **Show Apple devices and battery**; the trusted
USB/Wi-Fi companion route behind the same rows does not use Bluetooth and is
unaffected. While the switch is off, a phone advertisement is not a candidate
and no GATT session is opened, so no prompt can appear. A device that
advertises the standard Battery Service is still read: a keyboard or a mouse
answers without asking anything.

With the switch on, a session that ends without a reading is not retried on a
fixed one-minute cadence. The first consecutive failure waits one minute, the
second waits five, and the third suspends that UUID for the rest of the app
session, so a declined pairing cannot keep prompting. The panel's refresh button re-arms suspended devices; an ordinary
scan never does. A background refresh reads only the UUIDs the user selected,
and discovery-time first reads are limited to the popover's visible list.

Named Apple BLE UUID metadata is retained after a discovery scan expires so row
name, order, and hide preferences remain stable. Existing UUID metadata is
retained across upgrade. These UUIDs identify rows only; they do not represent
consent or a claim that a device belongs to the user. Classic Bluetooth and BLE
identities remain distinct. Profiler rows classified as unpaired ghosts are
excluded from Settings and the status popover; ordinary paired devices remain.

The scanner recognises Apple Continuity advertisement types `0x10` and `0x0C`,
and reads the standard Battery Service `180F/2A19`. Device Information reads are
limited to model `180A/2A24` and manufacturer `180A/2A29`. It opens no more than
two concurrent connections, applies an eight-second deadline and per-device
cooldown, and cancels work when visibility is lost. It performs no writes and
does not request USB access.

Automated tests cover UUID-based row persistence, same-name identity separation,
ghost exclusion, visible-viewport permits, Settings-only discovery, cancellation,
timeouts, and connection limits. Hardware behavior remains subject to testing
on supported devices.
