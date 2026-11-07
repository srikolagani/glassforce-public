# Show HN draft

## Note before you post

This file is an unpublished draft. Do not post it from this pull request.

https://github.com/srikolagani/glassforce is private today. Make the repository public before you post. Until you do, the link is dead.

Put the title in the Hacker News title field. The Show HN prefix uses a colon because that is the title format on the site. Paste the paragraphs under Post into the text field. Do not paste this note.

Do not ask for upvotes or comments.

The figure of under 50 ms is yours. This draft does not say that anyone measured it.

If you attach a screenshot, use the neutral glass panel and name it neutral-glass-panel.png. Do not use the old colored backdrop.

Before you post, confirm the sentences about open pull requests and about sync code that is not pushed yet. docs/launch/README.md records what was true on 5 November 2026.

## Title

Show HN: Glassforce, a native macOS command bar for Salesforce

## Post

I built Glassforce, a native macOS command bar for Salesforce. Option-Space opens a floating panel. You type a name. Fuzzy search finds the record, and Return opens it in Lightning.

The hotkey panel, fuzzy search, opening a record, the object picker, and OAuth connect work today. Fuzzy search stays under 50 ms. You choose the objects to search, including custom objects. The choices include Accounts, Contacts, Opportunities, Cases, Reports, and Setup pages.

You build Glassforce from source today. The app source that is pushed is on the open pull requests, and the main branch does not have all of it. The newest sync code is still on my Mac and is not pushed yet. Cloning the main branch does not give you the current app.

These parts are coming soon. They include Cmd-K actions, inline preview, natural language writes that you confirm before they run, a signed DMG, and `brew install --cask glassforce`. I have not published a public Salesforce package install link.

Sign-in is OAuth with PKCE. Tokens stay in the Keychain. There is no telemetry. Salesforce data stays on the Mac. Glassforce is not affiliated with Salesforce.

The license is MIT.

https://github.com/srikolagani/glassforce
