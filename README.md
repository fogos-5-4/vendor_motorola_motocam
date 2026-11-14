# Motorola Camera 4 for fogos (moto g34 5G)

Drop-in vendor tree for the stock Motorola camera for AOSP-based ROMs.
Optional — your ROM builds and runs fine without it.

## Install

From the root of your ROM source:

```bash
curl -LSs https://raw.githubusercontent.com/fogos-5-4/vendor_motorola_motocam/fogos/install-motocamera.sh | bash
```

Needs `git-lfs` — the camera APK is a 238 MB LFS object. If it's missing the
script stops.

The installer:

1. verifies it is running in a ROM source root
2. checks `git-lfs`
3. **stops** if `vendor/motorola/motocamera` already exists (it never overwrites)
4. clones this repo, pulls the LFS objects, and confirms `MotCamera4.apk` is the
   real file and not a 134-byte pointer
5. resolves the `hardware/dolby` overlap, if that tree is present
6. adds the `inherit-product` line to `device/motorola/fogos/device.mk`
7. installs and applies the cameraserver shutter-order patch


## What it installs

- **MotCamera4** (`com.motorola.camera3`, stock v9.1.30.65) — product priv-app,
  overrides Aperture and Camera2
- **MotCamera3AI** — content AI plugin
- **MotoSignatureApp**, **MotoSignature2App**, `com.motorola.motosignature` —
  MotCamera4 declares `motosignature` as a hard `uses-library`, so it will not
  install without them
- **MotorolaSettingsProvider**, `motsettings`, CameraExtensionsProxy
- Face-detection libs (`libAncFaceDetect`, `libancbase_fd`)
- Optional, on by default: Moto Camera Desktop and ImagerTuning-V + the
  `motorola.hardware.camera.imgtuner` HAL (`MOTOCAMERA_DESKTOP`,
  `MOTOCAMERA_IMAGERTUNING`)
- Stock camera properties — aux-camera and CFA packagelists
- SELinux starting point in `sepolicy/camera.te`

## Credits

- **Motorola Mobility** — the camera app, HAL and proprietary blobs
- **The LineageOS Project** — build conventions and extract-utils tooling
- **JNWSG** — original [vendor_motorola_MotCamera4](https://gitea.com/JNWSG/vendor_motorola_MotCamera4)
- All contributors who did the work

## Disclaimer

All proprietary files belong to Motorola Mobility. Provided as-is, no warranty.
Use at your own risk.

