# Publish the site

The files in this folder are the Glassforce marketing page. The repository stays private. This workflow does not change repository visibility.

## Turn on GitHub Pages

A push does not publish the site. `.github/workflows/pages.yml` deploys this folder only when one of these is true.

- You run the workflow yourself with workflow_dispatch.
- The repository variable `PAGES_ENABLED` is the string `true`.

1. Merge `.github/workflows/pages.yml` to the default branch.
2. Open Settings, then Pages. Set Source to GitHub Actions. Leave the repository private.
3. To publish on later pushes, open Settings, then Secrets and variables, then Actions, then the Variables tab. Create a repository variable named `PAGES_ENABLED` with the value `true`. Any other value leaves the deploy job skipped.
4. To publish once without that variable, open the Actions tab, choose the Pages workflow, and run it.

The job uploads this folder and deploys it with the GitHub Pages actions. It does not turn Pages on for you, and it does not change who can see the repository. Set the Pages source yourself before you expect a URL.

GitHub serves a project site from a subpath. The page uses relative URLs, so the same files work there and on a local server.

Start a local server from this folder.

```
python3 -m http.server
```

Open the local URL the server prints.

## Swap in a demo

The hero tries three sources, in order.

1. `demo.mp4`
2. `demo.gif`
3. The still `assets/mock-search-eae6d2a.png`

Put `demo.mp4` or `demo.gif` in this folder and reload. The page keeps the first file that is there. Until one of those files is present, the hero shows `mock-search-eae6d2a.png`. That file is a scripted mock from commit eae6d2a. The chip in the picture says Sandbox, not Demo. It is not a production org. The script prints that still. It does not select any other image.

If the browser asks for reduced motion, the page keeps the stills and does not play `demo.mp4` or `demo.gif`.

From this folder, run:

```
sh scripts/use-demo.sh
```

The script prints the file the page will use. When both demo files are present, it prints `demo.mp4`. When neither demo file is present, it prints `assets/mock-search-eae6d2a.png`.

## Keep a theme choice

The page stores the choice in `localStorage` under `glassforce-theme`. Leave the key unset, or set anything other than `light` or `dark`, and the page follows the system color scheme. The theme switch writes `light` or `dark`.
