# Link my Windows

Link your Android phone and Windows PC over the same Wi-Fi.

- **Screen mirroring:** see your phone screen on the PC (view only).
- **Webcam:** use the phone camera on the PC.
- **Clipboard sync:** copy on one device, paste on the other.
- **File transfer:** send files in both directions.

The same Flutter app runs on both. Android-only parts (screen capture) live in
`native_android/` and are copied in by the GitHub workflow.

## Get the apps from GitHub

Create a release with a new tag (for example `v1.1.0`). GitHub builds
`LinkMyWindows.apk` (Android) and `LinkMyWindows-Windows.zip` (Windows) and
attaches them to the release.

## Use it

1. Same Wi-Fi, app open on both devices. The PC shows a QR code.
2. On the phone, tap **Scan QR code** and point it at the PC screen. You are
   linked instantly. (You can still type the IP address and code by hand.)
3. Phone: tap **Share my screen** or **Use as webcam**.
4. PC: tap **View phone screen** or **View phone camera**.

## Notes

- The phone shows a permission prompt before sharing the screen.
- Android only lets an app read the clipboard while the app is open on screen,
  so phone-to-PC clipboard sync works while the app is open.
- The webcam only works while the app stays open on the phone. It is shown in
  a window on the PC. To use it in Zoom, Meet or Teams, open OBS Studio, add
  the window with Window Capture, and click Start Virtual Camera.
- Windows may ask to allow the app through the firewall: choose Allow for
  private networks.
- Frame rate is modest (about 5-10 frames per second) to keep it simple.
