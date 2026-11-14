# Installing and refreshing LifePath

LifePath is installed with SideStore and a free Apple ID. Tested on an iPhone 15 Pro with iOS 26.6.2, November 2026.

## Weekly refresh (the one chore)

Free signing lasts 7 days. Before it runs out:

1. Open **LocalDevVPN** and tap **Connect**.
2. Open **SideStore** → **My Apps** → **Refresh All**.

LifePath shows the current expiry date. If it lapses, LifePath won't open or record until you refresh. Your history is kept.

## Installing a new version

1. Connect **LocalDevVPN**.
2. In Safari, open <https://github.com/Maubro1/lifepath/releases> and tap **LifePath.ipa** under the newest version.
3. SideStore → **My Apps** → **+** → pick the downloaded `LifePath.ipa`.

Installing over the existing app keeps all data and doesn't use one of SideStore's weekly app IDs.

## Setting up from scratch (new phone or after a reset)

On the Windows laptop:

1. Install iTunes from Apple: <https://www.apple.com/itunes/download/win64>.
2. Install iloader: <https://iloader.app>.

On the iPhone:

3. Install **LocalDevVPN** from the App Store. Be on Wi-Fi.
4. Connect the iPhone by cable and tap **Trust**.
5. In iloader: sign in with your Apple ID, pick the iPhone, click **Install SideStore (Stable)**.
6. Settings → General → VPN & Device Management → trust your Apple ID. Settings → Privacy & Security → **Developer Mode** on (the phone restarts).
7. Connect LocalDevVPN, open SideStore, sign in, tap the **7 DAYS** button next to SideStore once.
8. Install LifePath as above. (Restoring a backup from inside LifePath arrives in a later stage.)

**Always use the same Apple ID in SideStore.** SideStore ties LifePath's identity to the Apple ID that signs it. Signing with a different Apple ID installs it as a separate app with an empty diary, and the old data can't be reached from it.

If SideStore says its pairing file is invalid (this can happen after an iOS update), reconnect the cable and use iloader → **Manage Pairing File** → **Place** next to SideStore.

Limits of a free Apple ID: 3 sideloaded apps at once, 10 new app IDs per week.
