Historical launch draft. Not a current feature or installation statement. Check the root README before reuse.

# r/salesforce draft

## Note before you post

This file is an unpublished draft. Do not post it from this pull request.

The separate sanitized public-source repository is https://github.com/srikolagani/glassforce-public. Do not make the original private repository or its history public.

Read the r/salesforce sidebar and the self-promotion rules before you post. This note does not quote them, because the rules change.

Say that you built Glassforce. The post starts with "I built this." Leave that sentence in the post.

Do not paste this text into r/MacApps. That subreddit has its own draft, and the wording is different on purpose.

The figure of under 50 ms is yours. This draft does not say that anyone measured it.

If you attach a screenshot, use the neutral glass panel and name it neutral-glass-panel.png. Do not use the old colored backdrop.

Before you post, confirm the sentences about open pull requests and about sync code that is not pushed yet. docs/launch/README.md records what was true on 5 November 2026.

## Title

I built a Mac command bar for Salesforce

## Post

I built this. Glassforce is a native macOS command bar for Salesforce. Option-Space opens a floating panel. Type a name and press Return to open the record in Lightning.

You choose which objects are searchable, including Accounts, Contacts, Opportunities, Cases, Reports, Setup pages, and custom objects. Fuzzy search stays under 50 ms.

What I can use today is the hotkey panel, fuzzy search, opening a record, the object picker, and OAuth connect. You build from source today. I have not published a public Salesforce package install link.

Open pull requests have the app source that is pushed. The main branch does not contain all of it. The newest sync code is still on my Mac and is not pushed yet. A clone of the main branch is not the app I am running.

Sign-in is OAuth with PKCE. Tokens stay in the Keychain. There is no telemetry. Salesforce data stays on the Mac. Glassforce is not affiliated with Salesforce.

The license is MIT.

Cmd-K actions, inline preview, natural language writes that you confirm before they run, a signed DMG, and `brew install --cask glassforce` are coming soon.

https://github.com/srikolagani/glassforce-public
