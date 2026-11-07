# Glassforce: test it like a brand-new user

Takes about 10 minutes on a Mac. Anything in a code block gets pasted into Terminal.

## 1. Remove the package from the demo org (browser, about 30 s)

In the demo org › Setup › **Installed Packages**: **Glassforce** row › **Uninstall** › tick **Yes, I want to uninstall…** › **Uninstall**. Wait for the row to disappear.

## 2. (optional) Record your run, Glassforce windows only

In a second Terminal tab:

```sh
~/gf-launch/record.sh 300
```

It captures only Glassforce's own windows, never the browser or your other screens. Ctrl-C stops it early. The video is saved to `~/gf-launch/glassforce-run.mp4`. The first time, macOS may ask to give Terminal screen-recording access.

## 3. Get the app from GitHub and install it

```sh
cd /tmp && rm -rf gf-try && git clone git@github.com:srikolagani/glassforce.git gf-try && cd gf-try
git checkout fix/onboarding-install-step   # or main, once this lands
export SWIFTPM_CUSTOM_LIBS_DIR=~/Library/Caches/glassforce-swiftpm   # only if your Command Line Tools need the workaround
scripts/install.sh
```

No env-file copy step. The packaged public client id ships in source. It takes about 2 minutes. Glassforce stays in the menu bar (the bolt) and does not open a window, a browser, or a sign-in sheet on its own. Click the bolt and choose **Search Salesforce**, or press **⌥ Space**, and the Welcome window opens.

## 4. Install the package (in the app, then the browser)

**Get Started** › **Continue** › **Custom Domain** › type your My Domain host › **Install Package**.
In the browser page that opens: **Install for Admins Only** › **Install** › **Done**.
Back in Glassforce: **Proceed to next step**.

## 5. Connect and confirm

**Connect** › sign in if asked › **Allow**.
Glassforce then shows **Is this the right org?** with the org name, username and host.
Click **Use this org**. (If it's the wrong org, click **Sign in to a different org** and try again.)

## 6. Search

Wait for the sync, then click **Start Searching**. Press **⌥ Space** anywhere, type `acme` (try the typo `acmee` too), and press **Return**. The record should open in Lightning. Clicking a row does the same.

## 7. Pick objects

Press **⌘ ,** (or click the gear in the panel) › Search objects. Turn on an object, for example Lead or a custom one, and it resyncs by itself.

## Start over (wipe the Mac side again)

```sh
pkill -x Glassforce; rm -rf /Applications/Glassforce.app ~/Library/Application\ Support/Glassforce ~/Library/Logs/Glassforce
defaults delete com.srikolagani.glassforce 2>/dev/null
while security delete-generic-password -s dev.glassforce.oauth >/dev/null 2>&1; do :; done
```

If something breaks, send `~/Library/Logs/Glassforce/glassforce.log`. It never contains tokens.

## Wipe browser leftovers

Clear these too so a fresh connect is not confused by leftover SSO cookies:

```bash
rm -rf ~/Library/HTTPStorages/com.srikolagani.glassforce
rm -rf ~/Library/WebKit/com.srikolagani.glassforce
rm -rf ~/Library/Cookies/com.srikolagani.glassforce* 2>/dev/null || true
```

## QA: target the onboarding window with Return / Space

Glassforce is an `LSUIElement` (accessory) app, so it never becomes frontmost to System Events.
For keyboard-injection QA on **Debug** builds only:

```bash
# Debug build + install, then:
open -a Glassforce --args --onboarding --qa-foreground
# Now System Events / osascript can keystroke Return/Space at Glassforce.
```

`--qa-foreground` sets a regular activation policy, activates the app, and makes the onboarding
window key. It is compiled out of **release** builds (the flag is ignored there).

