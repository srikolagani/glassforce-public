Historical launch draft. Not a current feature or installation statement. Check the root README before reuse.

# r/MacApps draft

## Note before you post

This file is an unpublished draft. Do not post it from this pull request.

The separate sanitized public-source repository is https://github.com/srikolagani/glassforce-public. Do not make the original private repository or its history public.

Read the r/MacApps sidebar before you post. This note does not quote it, because the rules change. A signed DMG and `brew install --cask glassforce` are coming soon, so the post tells readers to build from source. Check whether a post about building from source fits this subreddit before you submit.

Say that you built Glassforce. The post starts with "I built this." Leave that sentence in the post.

Do not paste this text into r/salesforce. That subreddit has its own draft, and the wording is different on purpose.

The figure of under 50 ms is yours. This draft does not say that anyone measured it.

If you attach a screenshot, use the neutral glass panel and name it neutral-glass-panel.png. Do not use the old colored backdrop. Do not imply that a DMG is attached.

Before you post, confirm the sentences about open pull requests and about sync code that is not pushed yet. docs/launch/README.md records what was true on 5 November 2026.

## Title

I built Glassforce, a native command bar for Salesforce

## Post

I built this. Glassforce is a native macOS command bar for Salesforce. Option-Space opens a floating panel. You type a name and press Return. Glassforce opens the record in Lightning.

The objects you can turn on include Accounts, Contacts, Opportunities, Cases, Reports, Setup pages, and custom objects. Fuzzy search stays under 50 ms.

On the build I run, the hotkey panel, fuzzy search, opening a record, the object picker, and OAuth connect work. You build it from source today.

The open pull requests contain the app source I have pushed. The main branch does not include the whole app. The newest sync code is still on my Mac and is not pushed yet. If you clone the main branch, you do not get the current app.

Sign-in is OAuth with PKCE. Tokens stay in the Keychain. There is no telemetry. Salesforce data stays on the Mac. The license is MIT. Glassforce is not affiliated with Salesforce.

Cmd-K actions are coming soon. So are inline preview, natural language writes that you confirm before they run, a signed DMG, and `brew install --cask glassforce`. I have not published a public Salesforce package install link.

https://github.com/srikolagani/glassforce-public
