# ROG Xbox Ally X20 speakers on SteamOS

Makes the internal speakers work on the **ASUS ROG Xbox Ally X20**, released 15 October 2026,
under SteamOS. Out of the box, SteamOS shows only HDMI audio, or "Dummy Output". After
this fix you get stereo speakers, the built-in microphones, the headphone jack and the headset mic.

Tested on:

| | |
|---|---|
| Device | ROG Xbox Ally X20, BIOS RC74XA.301 |
| SteamOS | 3.9.3 (Preview, build 20261015.100) |
| Kernel | `7.2.7-valve2-1-neptune-72-g31504582a073` |

The X20's firmware calls it **"ROG XBOX Ally X RC74XA"**, so the same name shows up in
`status` and in Linux's hardware info. That's normal. It has not been tested on the
original ROG Xbox Ally X. The installer checks the audio hardware ID (`1043:1954`) and
refuses to run if it doesn't match.

> **Use at your own risk.** The script changes the boot entry of the active SteamOS slot
> and loads a rebuilt kernel module, which marks the kernel as "tainted" (this is
> harmless). `uninstall` removes everything. If the device ever fails to boot, power it
> off and on a few times and SteamOS falls back to the other slot.

## Install

Open **Desktop Mode**, start **Konsole**, and run:

```sh
git clone https://github.com/SupremeRetroGaming/rog-ally-x20-steamos-speakers.git
cd rog-ally-x20-steamos-speakers
sudo ./ally-audio-fix-debian.sh install
```

```sh
git clone https://github.com/hungarianhc/rog-ally-x20-steamos-speakers.git
cd rog-ally-x20-steamos-speakers
sudo ./ally-audio-fix.sh install
```

Then reboot. If you have never set a password for the `deck` user, run `passwd` first so
that `sudo` works.

To check that it worked, run:

```sh
sudo ./ally-audio-fix-debian.sh status
```

```sh
sudo ./ally-audio-fix.sh status
```

The `card:` line should include `spk:tas2783`. The volume slider in Game Mode should now
control the speakers.

## After a SteamOS update

SteamOS updates replace the kernel and switch to the other slot, so the speakers go
quiet again until you rerun the installer. If this repo already has a prebuilt module for
the new kernel (`prebuilt/<kernel version>/`), just pull and install:

```sh
cd rog-ally-x20-steamos-speakers
git pull
sudo ./ally-audio-fix.sh install
```

If not, build the module yourself first. Run `build` **without** `sudo`. It uses
rootless podman (included in SteamOS) and needs about 1 GB of space in your home folder:

```sh
./ally-audio-fix.sh build
sudo ./ally-audio-fix.sh install
```

## Uninstall

```sh
sudo ./ally-audio-fix.sh uninstall
```

Then reboot.

## What's wrong, and what the script does

The speakers are two TI **TAS2783** smart amps on the AMD audio coprocessor's SoundWire
bus. Four separate problems keep them silent on SteamOS. The script fixes each one:

1. **The BIOS disables the SoundWire driver.** The ACPI tables set
   `acp-audio-config-flag = 0x10` ("legacy driver, digital mics only"), so Linux's
   SoundWire and SOF drivers back off. Windows ignores this flag. The script gives the
   kernel a copy of that ACPI table with the flag cleared, loaded at boot as an early
   initrd ([ACPI table upgrade](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html)).
   This is the only change to the boot setup.

2. **The kernel doesn't know this board's wiring.** Retail units put both amps on
   SoundWire link 0 and the RT721 headset codec on link 1. The BIOS chooses this through
   a board strap on GPIO 104. The kernel's only TAS2783 layout for this device expects
   the amps on link 1, so it falls back to a headset-only card. The script loads a
   `snd-soc-acpi-amd-match` module with a layout for link 0 added
   ([`patches/`](patches/)). A modprobe hook loads it in place of the stock module, and
   only for the exact kernel it was built for. On any other kernel the stock module
   loads and nothing breaks.

3. **The amps need tuning files.** TI publishes them in
   [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/ti/audio/tas2783)
   (licence: redistributable, see `WHENCE`). The files there carry an extra digit for
   the **speaker supplier**: this model ships with either "JGX" or "LS" speakers, which
   need different tuning. The script reads the BIOS's own `SPEAKER_ID` UEFI variable to
   choose, downloads the matching pair from a pinned linux-firmware commit, checks their
   SHA-256, and saves them under the names the driver requests.

4. **The audio server has no speaker profile.** SteamOS's `alsa-ucm-conf` predates
   TAS2783 support, so PipeWire shows "Dummy Output". The script adds upstream's
   [`sof-soundwire/tas2783.conf`](https://github.com/alsa-project/alsa-ucm-conf/blob/master/ucm2/sof-soundwire/tas2783.conf)
   ([`ucm/`](ucm/), BSD-3-Clause). It uses a symlink overlay pointed to by
   `ALSA_CONFIG_UCM2`, so SteamOS's own UCM files stay in use.

Everything except the boot-entry change lives in `/var/lib/ally-audio-fix`,
`/etc/modprobe.d/ally-audio-fix.conf` and `/etc/environment.d/90-ally-audio-fix.conf`.

## Known issues

- The amps' feedback capture stream (`SDW0-PIN4-CAPTURE-SmartAmp`) fails to start. No
  application uses it, and it doesn't affect playback.
- Only the active SteamOS slot is changed; see "After a SteamOS update".

## Upstream status

| Piece | Status |
|---|---|
| ACPI flag | BIOS bug; Linux has quirks for other laptops with the same problem |
| Link-0 layout | patch in [`patches/`](patches/), not yet submitted |
| Tuning files | in linux-firmware; the kernel requests a different file name, see [this report](https://ratatoskr.run/linux-sound/2026/08/17413658) |
| UCM profile | in alsa-ucm-conf since July 2026; not yet in SteamOS |

## Notes for developers

- An upstream proposal gives each mono amp a single channel of the stereo stream
  ([thread](https://ratatoskr.run/linux-sound/2026/07/17279211/t)). **Don't apply it on
  this device.** It silences the right amp. Here each amp picks its own side, set by the
  BIOS's SDCA init table (PPU21 = `0x01` left, `0x04` right), so the stock driver
  already plays correct stereo.
- `snd-soc-acpi-amd-match` is built from upstream stable sources at the matching
  version. For 7.2.7 they are identical to Valve's tree.

## Tip jar

If this got your speakers working and you'd like to say thanks:
[paypal.me/hungarianhc](https://paypal.me/hungarianhc). Totally optional.

## License

GPL-2.0 (see `LICENSE`), except `ucm/tas2783.conf`, which comes from alsa-ucm-conf
(BSD-3-Clause).
