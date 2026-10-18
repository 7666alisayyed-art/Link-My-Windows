# Link my Windows

Link your Android phone and Windows PC over the same Wi-Fi. Send your clipboard,
text and files between them. The same Flutter code runs on both.

## Get the apps from GitHub

1. Create a new repository on GitHub and upload everything in this folder
   (keep the `.github` folder).
2. Open the **Releases** step by creating a tag. On GitHub: **Releases > Draft a
   new release > Choose a tag**, type `v1.0.0`, choose **Create new tag**, then
   **Publish release**. (Or use **Actions > Build apps > Run workflow** to get
   the files as downloadable artifacts instead.)
3. Wait about 10 minutes. The release will then have two files:
   - `LinkMyWindows.apk` - download on your Android phone and install it
     (allow "install unknown apps" when asked).
   - `LinkMyWindows-Windows.zip` - download on Windows, unzip, run
     `link_my_windows.exe`.

## Use it

1. Connect both devices to the same Wi-Fi and open the app on both.
2. Each device shows its IP address and a 6-digit pairing code.
3. On one device, type the other device's IP address and code, then tap Connect.
4. Send your clipboard, type text, or send a file.

Received files are saved in a folder called `Link my Windows` (Downloads on
Windows; the app's own storage folder on Android - the Activity list shows the
exact path).

On first run Windows may ask to allow the app through the firewall. Choose
**Allow** for private networks.

## Not included

Mirroring Android notifications to Windows needs native Android code and
is not part of this version.
