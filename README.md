# Omarchy Mac Installer

Source for a macOS app that installs Omarchy Linux alongside macOS on Apple
Silicon. This fork tracks
[omacom/omarchy-mac-installer](https://github.com/omacom/omarchy-mac-installer),
extracted from [maralcbr/omarchy-mx-mac](https://github.com/maralcbr/omarchy-mx-mac).

The app is called Omarchy Installer. It keeps the `com.omarchy.mx.*` app IDs
and the original release settings. The package also removes a copy with the
old name, Omarchy MX Mac Installer.

This source snapshot is not a tested installation release. Building the app
does not establish that it is safe to install on a real Mac. The inherited
release tools still target the original publisher's services.

## Mac support

The [model list](scripts/supported-models.json) names 34 M1, M2 and M3 boards.
Check that list before building a catalog. A release must enable all supported
boards, not a subset.

- M3 Ultra Mac Studio (`apple,j575d`) is refused. The pinned engine has no
  entry for it and cannot inspect or plan its disk.
- M4 and newer Macs are refused, including `apple,j614s`.
- M3 uses software rendering (llvmpipe), not an accelerated GPU driver.

These are this snapshot's limits, not a claim about all Linux installers.
See [the release guide](Release/README.md) for catalog rules.

## Install flow

Back up macOS before changing the disk. The app works through these steps:

1. Check the Mac model and the bundled inspection engine.
2. Download and verify the payload. Propose the disk layout. Confirm your
   backup, choose the Linux size and choose whether to encrypt it.
3. Enter a macOS admin account and password. The app keeps them in memory,
   uses them once, and starts the disk changes only after approval.
4. Write the install, with checkpoints and a journal for recovery.
5. Shut down. Hold the power button until Loading startup options appears.
   Choose Omarchy > Finish Installation. Sign in once with your macOS account.
6. Confirm the new system can boot.

The layout uses free space for an APFS container, EFI, Linux boot and Linux
root partitions. The APFS container is at most 4 GiB. The engine reserves
38,000,000,000 bytes for macOS, regardless of disk size.

Encryption is on by default. You can turn it off on the plan screen. The
Omarchy password you create at first boot also unlocks the disk. There is no
separate recovery key. Keep that password safe.

This version refuses to install over an existing Omarchy install. Use
Installation > Remove Omarchy first. Removal requires the exact phrase
`delete omarchy installation and data` and gives the space back to macOS.
Read [the removal guide](Development/Removal.md) before using it.

A failed or interrupted step blocks a new install until its journal is
resolved. Do not assume that a failed operation left the disk unchanged.

## Build and test

The portable tests need Bash 5+, Python 3.12+, Git and standard Unix tools,
including GNU `sha256sum`. They use fixtures and install nothing:

```sh
bash test/all
```

The Swift app needs macOS 15+ and Swift 6.2+. Start with strict format checks:

```sh
xcrun swift-format lint --strict --recursive Package.swift Sources Plugins Tests
```

Then run the debug and release tests. The
[validation guide](docs/validation.md) lists the commands and prior results.
Use its simulation path to review the UI without disk changes.

[Packaging/build-app.sh](Packaging/README.md) builds the app without
installing it. It needs the release inputs and the exact pinned engine archive.
Read [the engine guide](docs/extraction.md) before packaging.

CI checks the portable suite, Swift formatting and tests, and image-builder
sources. Swift runs on an Apple Silicon macOS 15 runner. CI logs stay available
for 14 days. A passing build is not a physical install test.

## Engine and Linux image

`Engine/` holds the engine source lock, Python overlay and rebuild tools.
[The engine guide](docs/extraction.md) records its versions, hashes and
reproduction steps.

`image-builder/` produces the Apple Silicon Linux image. Start with its
[build guide](image-builder/README.md); see also
[entry points and checks](docs/image-builder.md) and
[component sources](docs/image-producer.md).

## More documentation

- [Validation and test results](docs/validation.md)
- [Removing Omarchy](Development/Removal.md)
- [Debug simulations](Development/Simulation.md)
- [Staging and read-back behavior](Development/Installation-performance.md)
- [App packaging and notarization](Packaging/README.md)
- [Release descriptors, trust and channels](Release/README.md)
- [Private tester build](Packaging/private-test/README.md)

## License

The original [MIT license](LICENSE), copyright notice and Git history are
retained. Engine dependencies keep their own licenses. Their source revisions
are in `Engine/source-lock.json`.
